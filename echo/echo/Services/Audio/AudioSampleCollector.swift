import AVFoundation
import Accelerate
import os

/// One flush of the capture ring. RAM engines get samples; Apple gets the CAF URL.
struct AudioCaptureSnapshot: Sendable {
    var samples: [Float]
    var fileURL: URL?

    func trimmingSilence(padSeconds: Double = 0.15) -> AudioCaptureSnapshot {
        guard !samples.isEmpty, let trimmed = AudioSampleCollector.trimmed(samples, padSeconds: padSeconds) else {
            return self
        }
        return AudioCaptureSnapshot(samples: trimmed, fileURL: fileURL)
    }
}

private final class HandlerBox: @unchecked Sendable {
    var handler: ((AVAudioPCMBuffer) -> Void)?
}

/// 16 kHz mono sink. The CoreAudio tap only memcpy's into a preallocated ring.
/// A dedicated consumer thread writes CAF / copies RAM. Never allocate on the tap.
nonisolated final class AudioSampleCollector: @unchecked Sendable {
    private static let ringFrames = Int(AudioResampler.targetSampleRate) * 180
    /// Whisper / Parakeet stay in RAM until this many frames, then spill to CAF.
    private static let maxRAMFrames = Int(AudioResampler.targetSampleRate) * 90
    private static let drainChunk = 4_096

    private struct RingState {
        var capturing = false
        var writeIndex = 0
        var count = 0
        var generation: UInt64 = 0
    }

    private let ring: UnsafeMutablePointer<Float>
    private let ringFrames: Int
    private let ringState = OSAllocatedUnfairLock(initialState: RingState())
    private let liveHandler = OSAllocatedUnfairLock<HandlerBox>(initialState: HandlerBox())
    private let drainSemaphore = DispatchSemaphore(value: 0)
    private let ioQueue = DispatchQueue(label: "echo.audio.sink", qos: .userInitiated)
    private let stopConsumer = OSAllocatedUnfairLock(initialState: false)

    private var samples: [Float] = []
    private var audioFile: AVAudioFile?
    private var fileURL: URL?
    private var keepSamples = true
    private var spilled = false
    private var drainBuffer: AVAudioPCMBuffer?

    var isCapturing: Bool {
        ringState.withLock { $0.capturing }
    }

    /// Bumped in `beginSession`. Leftover cleanup must pass this or it can wipe the next take.
    var sessionGeneration: UInt64 {
        ringState.withLock { $0.generation }
    }

    init() {
        ringFrames = Self.ringFrames
        ring = .allocate(capacity: ringFrames)
        ring.initialize(repeating: 0, count: ringFrames)
        startConsumer()
    }

    deinit {
        stopConsumer.withLock { $0 = true }
        drainSemaphore.signal()
        ring.deallocate()
    }

    func beginSession(keepSamplesInMemory: Bool = true) {
        ringState.withLock { state in
            state.generation &+= 1
            state.capturing = false
            state.writeIndex = 0
            state.count = 0
        }
        ioQueue.sync {
            #if DEBUG
            Self.auditTemporaryRecordings(context: "begin", keeping: nil)
            #endif
            samples.removeAll(keepingCapacity: true)
            spilled = false
            keepSamples = keepSamplesInMemory
            closeWriter()
            if let fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            fileURL = nil
            drainBuffer = AVAudioPCMBuffer(
                pcmFormat: AudioResampler.mono16kFormat(),
                frameCapacity: AVAudioFrameCount(Self.drainChunk)
            )
            if !keepSamplesInMemory {
                openFile()
                if audioFile == nil {
                    keepSamples = true
                }
            }
        }
        ringState.withLock { $0.capturing = true }
    }

    func endSession() async -> AudioCaptureSnapshot {
        ringState.withLock { $0.capturing = false }
        drainSemaphore.signal()
        return await withCheckedContinuation { continuation in
            ioQueue.async {
                self.flushWork()
                self.closeWriter()
                continuation.resume(returning: self.makeSnapshot())
            }
        }
    }

    func setLiveHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        liveHandler.withLock { $0.handler = handler }
    }

    func append(converted buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        let accepted = ringState.withLock { state -> Int in
            guard state.capturing else { return 0 }
            let room = ringFrames - state.count
            let copyCount = min(frames, room)
            guard copyCount > 0 else { return 0 }
            copyIntoRing(from: channel, count: copyCount, writeIndex: state.writeIndex)
            state.writeIndex = (state.writeIndex + copyCount) % ringFrames
            state.count += copyCount
            return copyCount
        }
        if accepted > 0 {
            drainSemaphore.signal()
        }
        liveHandler.withLock { $0.handler }?(buffer)
    }

    func snapshot() async -> [Float] {
        drainSemaphore.signal()
        return await withCheckedContinuation { continuation in
            ioQueue.async {
                self.flushWork()
                if self.keepSamples, !self.spilled {
                    continuation.resume(returning: self.samples)
                    return
                }
                if let fileURL = self.fileURL {
                    continuation.resume(returning: Self.readFloats(from: fileURL))
                    return
                }
                continuation.resume(returning: self.samples)
            }
        }
    }

    func recordingURL() async -> URL? {
        drainSemaphore.signal()
        return await withCheckedContinuation { continuation in
            ioQueue.async {
                self.flushWork()
                continuation.resume(returning: self.fileURL)
            }
        }
    }

    /// Trims leading/trailing silence, keeping a 150ms pad. Skips if speech starts too soon.
    /// Runs on `ioQueue` — never `ioQueue.sync` from the caller (including MainActor).
    /// On failure the original RAM samples / CAF stay in place.
    func trimSilence(padSeconds: Double = 0.15) async {
        drainSemaphore.signal()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                self.flushWork()
                self.closeWriter()
                if self.keepSamples, !self.spilled, !self.samples.isEmpty {
                    if let trimmed = Self.trimmed(self.samples, padSeconds: padSeconds) {
                        self.samples = trimmed
                    }
                    continuation.resume()
                    return
                }
                if let url = self.fileURL, let trimmedURL = Self.trimFile(at: url, padSeconds: padSeconds) {
                    self.fileURL = trimmedURL
                }
                continuation.resume()
            }
        }
    }

    func reset() async {
        await cleanupRecordingFile()
    }

    func cleanupRecordingFile(expectedGeneration: UInt64? = nil) async {
        let matches = ringState.withLock { state -> Bool in
            if let expectedGeneration, state.generation != expectedGeneration {
                return false
            }
            state.capturing = false
            state.writeIndex = 0
            state.count = 0
            return true
        }
        guard matches else { return }
        drainSemaphore.signal()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                if let expectedGeneration, self.ringState.withLock({ $0.generation }) != expectedGeneration {
                    continuation.resume()
                    return
                }
                self.liveHandler.withLock { $0.handler = nil }
                self.flushWork()
                self.closeWriter()
                self.samples.removeAll(keepingCapacity: true)
                self.spilled = false
                if let fileURL = self.fileURL {
                    try? FileManager.default.removeItem(at: fileURL)
                }
                self.fileURL = nil
                #if DEBUG
                Self.auditTemporaryRecordings(context: "reset", keeping: nil)
                #endif
                continuation.resume()
            }
        }
    }

    private func startConsumer() {
        let thread = Thread { [weak self] in
            while true {
                self?.drainSemaphore.wait()
                guard let self else { return }
                if self.stopConsumer.withLock({ $0 }) { return }
                self.ioQueue.sync {
                    self.flushWork()
                }
            }
        }
        thread.name = "echo.audio.sink.thread"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func flushWork() {
        while true {
            let copied = copyOutOfRing(max: Self.drainChunk)
            if copied == 0 { return }
            ingestDrainedFrames(copied)
        }
    }

    private func ingestDrainedFrames(_ count: Int) {
        guard count > 0, let drainBuffer, let dest = drainBuffer.floatChannelData?[0] else { return }
        drainBuffer.frameLength = AVAudioFrameCount(count)

        if keepSamples, !spilled {
            samples.append(contentsOf: UnsafeBufferPointer(start: dest, count: count))
            if samples.count >= Self.maxRAMFrames, spillRAMToFile() {
                return
            }
        }

        if audioFile != nil {
            try? audioFile?.write(from: drainBuffer)
        }
    }

    /// Writes RAM to CAF and clears it. On failure, keeps samples so a long take is not lost.
    @discardableResult
    private func spillRAMToFile() -> Bool {
        openFile()
        guard audioFile != nil, let all = AudioResampler.pcmBuffer(from: samples) else {
            abandonFailedWriter()
            return false
        }
        do {
            try audioFile?.write(from: all)
        } catch {
            abandonFailedWriter()
            return false
        }
        spilled = true
        samples.removeAll(keepingCapacity: false)
        return true
    }

    private func abandonFailedWriter() {
        closeWriter()
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
    }

    private func copyIntoRing(from source: UnsafePointer<Float>, count: Int, writeIndex: Int) {
        let first = min(count, ringFrames - writeIndex)
        ring.advanced(by: writeIndex).update(from: source, count: first)
        if first < count {
            ring.update(from: source.advanced(by: first), count: count - first)
        }
    }

    @discardableResult
    private func copyOutOfRing(max maxFrames: Int) -> Int {
        guard let drainBuffer, let dest = drainBuffer.floatChannelData?[0] else { return 0 }
        return ringState.withLock { state in
            let copyCount = min(maxFrames, state.count)
            guard copyCount > 0 else { return 0 }
            let readIndex = (state.writeIndex - state.count + ringFrames) % ringFrames
            let first = min(copyCount, ringFrames - readIndex)
            dest.update(from: ring.advanced(by: readIndex), count: first)
            if first < copyCount {
                dest.advanced(by: first).update(from: ring, count: copyCount - first)
            }
            state.count -= copyCount
            return copyCount
        }
    }

    private func openFile() {
        if audioFile != nil { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-\(UUID().uuidString).caf")
        let format = AudioResampler.mono16kFormat()
        audioFile = try? AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        if audioFile != nil {
            fileURL = url
        }
    }

    private func closeWriter() {
        audioFile = nil
    }

    /// RAM path returns in-memory floats. File-only Apple capture returns the URL and skips a CAF read.
    /// Spilled Parakeet/Whisper (>90s) reads the file so the take is not lost.
    private func makeSnapshot() -> AudioCaptureSnapshot {
        if keepSamples, !spilled {
            return AudioCaptureSnapshot(samples: samples, fileURL: fileURL)
        }
        if keepSamples || spilled || fileURL == nil {
            if let fileURL {
                return AudioCaptureSnapshot(samples: Self.readFloats(from: fileURL), fileURL: fileURL)
            }
            return AudioCaptureSnapshot(samples: samples, fileURL: nil)
        }
        return AudioCaptureSnapshot(samples: [], fileURL: fileURL)
    }

    #if DEBUG
    private static func auditTemporaryRecordings(context: String, keeping keep: URL?) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let now = Date()
        for url in items {
            let name = url.lastPathComponent
            guard name.hasPrefix("echo-"), url.pathExtension == "caf" || url.pathExtension == "wav" else {
                continue
            }
            if url == keep { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(modified) > 3600 {
                try? fm.removeItem(at: url)
                print("[Echo] removed stale temp audio (\(context)): \(name)")
            } else {
                print("[Echo] temp audio present (\(context)): \(name)")
            }
        }
    }
    #endif

    private static func readFloats(from url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        guard format.channelCount == 1, let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { return [] }
        do {
            try file.read(into: buffer)
        } catch {
            return []
        }
        return AudioResampler.floats(from: buffer)
    }

    fileprivate static func trimmed(_ samples: [Float], padSeconds: Double) -> [Float]? {
        guard let range = silenceFreeRange(in: samples, padSeconds: padSeconds) else { return nil }
        return Array(samples[range])
    }

    private static func trimFile(at url: URL, padSeconds: Double) -> URL? {
        let floats = readFloats(from: url)
        guard let range = silenceFreeRange(in: floats, padSeconds: padSeconds) else { return nil }
        guard let out = AudioResampler.pcmBuffer(from: Array(floats[range])) else { return nil }
        let trimmedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-\(UUID().uuidString).caf")
        do {
            let writer = try AVAudioFile(
                forWriting: trimmedURL,
                settings: AudioResampler.mono16kFormat().settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try writer.write(from: out)
        } catch {
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        return trimmedURL
    }

    /// Returns a range to keep, or nil if trimming would risk the first words.
    private static func silenceFreeRange(in samples: [Float], padSeconds: Double) -> Range<Int>? {
        let count = samples.count
        let rate = Int(AudioResampler.targetSampleRate)
        let pad = Int(padSeconds * AudioResampler.targetSampleRate)
        guard count > pad * 4 else { return nil }

        let window = max(rate / 100, 80)
        var first = -1
        var last = -1
        var i = 0
        while i + window <= count {
            var rms: Float = 0
            samples.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                vDSP_rmsqv(base + i, 1, &rms, vDSP_Length(window))
            }
            if rms > 0.012 {
                if first < 0 { first = i }
                last = i + window
            }
            i += window
        }
        guard first >= 0, last > first else { return nil }
        if first < pad / 2 { return nil }
        let start = max(0, first - pad)
        let end = min(count, last + pad)
        if end - start >= count - pad / 4 { return nil }
        return start..<end
    }
}
