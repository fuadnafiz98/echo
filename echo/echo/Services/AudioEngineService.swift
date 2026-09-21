import AVFoundation
import Accelerate
import os

/// Owns `AVAudioEngine`. Every engine call runs on one serial queue, never on the main thread.
///
/// `engine.start()` is a CoreAudio device start: tens of milliseconds warm, and far worse when
/// `coreaudiod` has idled the device or the input is Bluetooth. Doing that synchronously from the
/// hotkey handler is what made the overlay appear late. The queue is serial, so a stop enqueued
/// while a start is still running is still ordered correctly.
nonisolated final class AudioGraph: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "echo.audio.graph", qos: .userInitiated)
    private let collector: AudioSampleCollector
    private let resampler: StreamingResampler
    private let levelClock: LevelPublishClock
    private let rmsScratch: RMSScratch
    private let firstBufferAt = OSAllocatedUnfairLock(initialState: CFAbsoluteTime?.none)

    /// Queue-confined.
    private var tapInstalled = false
    private var tapFormat: AVAudioFormat?

    /// Block-based observers are keyed by this token, not by `self`, so it has to be kept.
    private let configurationObserver = OSAllocatedUnfairLock(initialState: NSObjectProtocol?.none)

    init(
        collector: AudioSampleCollector,
        resampler: StreamingResampler,
        levelClock: LevelPublishClock,
        rmsScratch: RMSScratch
    ) {
        self.collector = collector
        self.resampler = resampler
        self.levelClock = levelClock
        self.rmsScratch = rmsScratch

        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        configurationObserver.withLock { $0 = observer }
    }

    deinit {
        if let observer = configurationObserver.withLock({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Fire-and-forget graph warm. Safe to call repeatedly (launch, wake, device change).
    func prepare() {
        queue.async {
            try? self.installTapLocked()
            self.prepareResamplerLocked()
            if !self.engine.isRunning {
                self.engine.prepare()
            }
        }
    }

    /// Returns true if the CoreAudio device actually had to be started, false if it was already
    /// running. Worth distinguishing: a cold start is the expensive case.
    @discardableResult
    func start() async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            queue.async {
                do {
                    try self.installTapLocked()
                    if self.engine.isRunning {
                        continuation.resume(returning: false)
                        return
                    }
                    self.prepareResamplerLocked()
                    self.engine.prepare()
                    try self.engine.start()
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops the device so the microphone indicator goes out between takes.
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.engine.isRunning {
                    self.engine.stop()
                }
                continuation.resume()
            }
        }
    }

    func teardown() {
        queue.sync {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            if engine.isRunning {
                engine.stop()
            }
            engine.reset()
            resampler.reset()
            tapFormat = nil
        }
    }

    /// Reinstalls the tap against the current hardware format.
    ///
    /// Without this, waking from sleep or connecting headphones leaves a tap bound to a stale
    /// format: the converter rejects every buffer and the take comes back empty.
    func refresh() {
        queue.async {
            // By the time this notification arrives the engine has usually stopped itself, so
            // `isRunning` is already false mid-take. Ask the sink whether a take is in flight,
            // otherwise a device change silently kills the rest of the recording.
            let wasRunning = self.engine.isRunning || self.collector.isCapturing
            if self.engine.isRunning {
                self.engine.stop()
            }
            if self.tapInstalled {
                self.engine.inputNode.removeTap(onBus: 0)
                self.tapInstalled = false
            }
            self.resampler.reset()
            self.tapFormat = nil
            try? self.installTapLocked()
            self.prepareResamplerLocked()
            self.engine.prepare()
            if wasRunning {
                try? self.engine.start()
            }
        }
    }

    func markTakeStart() {
        firstBufferAt.withLock { $0 = nil }
    }

    /// Milliseconds from `reference` to the first captured buffer, once one has arrived.
    /// Read after the take; the audio thread only stores a timestamp.
    func firstBufferDelay(since reference: CFAbsoluteTime) -> Double? {
        guard let stamp = firstBufferAt.withLock({ $0 }) else { return nil }
        return (stamp - reference) * 1000
    }

    private func handleConfigurationChange() {
        Latency.note("audio configuration changed — reinstalling tap")
        refresh()
    }

    // MARK: - Queue-confined

    private func prepareResamplerLocked() {
        guard !engine.isRunning else { return }
        let format = tapFormat ?? engine.inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return }
        resampler.prepare(inputFormat: format)
    }

    private func installTapLocked() throws {
        if tapInstalled { return }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw NSError(
                domain: "EchoAudio",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Microphone isn’t available. Pick a mic in System Settings → Sound."
                ]
            )
        }

        let sink = collector
        let resampler = resampler
        let clock = levelClock
        let scratch = rmsScratch
        let stamp = firstBufferAt
        resampler.prepare(inputFormat: format)
        tapFormat = format

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            if let converted = resampler.convert(buffer) {
                sink.append(converted: converted)
            }

            guard sink.isCapturing else { return }

            stamp.withLock { existing in
                if existing == nil { existing = CFAbsoluteTimeGetCurrent() }
            }

            let now = CFAbsoluteTimeGetCurrent()
            guard now - clock.last >= 1.0 / 24.0 else { return }
            clock.last = now
            clock.store(AudioGraph.rmsEnergy(buffer: buffer, scratch: scratch))
        }
        tapInstalled = true
    }

    nonisolated private static func rmsEnergy(buffer: AVAudioPCMBuffer, scratch: RMSScratch) -> Float {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var rms: Float = 0
        var peak: Float = 0

        if let samples = buffer.floatChannelData {
            vDSP_rmsqv(samples[0], 1, &rms, vDSP_Length(frameCount))
            vDSP_maxmgv(samples[0], 1, &peak, vDSP_Length(frameCount))
        } else if let samples = buffer.int16ChannelData {
            let frames = min(frameCount, scratch.capacity)
            vDSP_vflt16(samples[0], 1, scratch.floats, 1, vDSP_Length(frames))
            var scale: Float = 1 / 32768
            vDSP_vsmul(scratch.floats, 1, &scale, scratch.floats, 1, vDSP_Length(frames))
            vDSP_rmsqv(scratch.floats, 1, &rms, vDSP_Length(frames))
            vDSP_maxmgv(scratch.floats, 1, &peak, vDSP_Length(frames))
        } else {
            return 0
        }

        let mixed = max(rms * 10, peak * 1.4)
        let gated = max(mixed - 0.018, 0)
        let level = min(gated / 0.24, 1)
        return level < 0.01 ? 0 : pow(level, 1.18)
    }
}

@MainActor
final class AudioEngineService {
    private let collector = AudioSampleCollector()
    private let resampler = StreamingResampler()
    private let levelClock = LevelPublishClock()
    private let rmsScratch = RMSScratch()
    private let graph: AudioGraph

    private var history = [Float](repeating: 0, count: OverlayMetrics.barCount)
    private var historyWrite = 0
    private var envelope: Float = 0

    init() {
        graph = AudioGraph(
            collector: collector,
            resampler: resampler,
            levelClock: levelClock,
            rmsScratch: rmsScratch
        )
    }

    var sampleCollector: AudioSampleCollector { collector }

    func prepareGraph() {
        graph.prepare()
    }

    /// Re-arms the graph after sleep, display change, or a default-device swap.
    func refreshGraph() {
        graph.refresh()
    }

    /// Async on purpose: the CoreAudio device start must not block the hotkey.
    /// Returns true if the microphone had to be started from cold.
    @discardableResult
    func beginCapture(keepSamplesInMemory: Bool = true) async throws -> Bool {
        collector.beginSession(keepSamplesInMemory: keepSamplesInMemory)
        resetHistory()
        envelope = 0
        levelClock.reset()
        graph.markTakeStart()
        return try await graph.start()
    }

    @discardableResult
    func endCapture() async -> AudioCaptureSnapshot {
        let snapshot = await collector.endSession()
        resetHistory()
        envelope = 0
        levelClock.reset()
        await graph.stop()
        return snapshot
    }

    /// Milliseconds from `reference` to the first captured buffer of this take.
    func firstBufferDelay(since reference: CFAbsoluteTime) -> Double? {
        graph.firstBufferDelay(since: reference)
    }

    func pullLevels() -> [Float] {
        if let energy = levelClock.takeEnergy() {
            applyEnergy(energy)
        }
        let count = OverlayMetrics.barCount
        var ordered = [Float](repeating: 0, count: count)
        for index in 0..<count {
            ordered[index] = history[(historyWrite + index) % count]
        }
        return ordered
    }

    func teardown() {
        graph.teardown()
        resetHistory()
        Task { await collector.reset() }
    }

    private func resetHistory() {
        history = [Float](repeating: 0, count: OverlayMetrics.barCount)
        historyWrite = 0
    }

    private func applyEnergy(_ energy: Float) {
        let attack: Float = 0.62
        let release: Float = 0.26
        let alpha = energy > envelope ? attack : release
        envelope += (energy - envelope) * alpha

        let displayedLevel = max(energy, envelope * 0.28)
        let count = OverlayMetrics.barCount
        historyWrite = (historyWrite + count - 1) % count
        history[historyWrite] = displayedLevel
    }
}

nonisolated final class RMSScratch: @unchecked Sendable {
    let floats: UnsafeMutablePointer<Float>
    let capacity: Int

    init(capacity: Int = 8_192) {
        self.capacity = capacity
        floats = .allocate(capacity: capacity)
        floats.initialize(repeating: 0, count: capacity)
    }

    deinit {
        floats.deallocate()
    }
}

nonisolated final class LevelPublishClock: @unchecked Sendable {
    private struct State {
        var lastPublish: CFAbsoluteTime = 0
        var energy: Float = 0
        var pending = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var last: CFAbsoluteTime {
        get { state.withLock { $0.lastPublish } }
        set { state.withLock { $0.lastPublish = newValue } }
    }

    func store(_ value: Float) {
        state.withLock {
            $0.energy = value
            $0.pending = true
        }
    }

    func takeEnergy() -> Float? {
        state.withLock {
            guard $0.pending else { return nil }
            $0.pending = false
            return $0.energy
        }
    }

    func reset() {
        state.withLock {
            $0.lastPublish = 0
            $0.energy = 0
            $0.pending = false
        }
    }
}
