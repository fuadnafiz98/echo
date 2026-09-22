import AVFoundation
import Accelerate
import CoreAudio
import os

/// Input-only microphone capture on a CoreAudio IOProc.
///
/// Not `AVAudioEngine`: the engine always runs an output unit on the default output device,
/// which is usually the headphones the user is listening on, and it follows the default input
/// even when that is a Bluetooth headset. Either of those can change what the user hears.
/// An IOProc on the chosen input device opens that device only, and `AudioInputDevices`
/// keeps it off Bluetooth headsets whenever there is another mic.
///
/// Control calls run on one serial queue, never on the main thread. A cold device start can
/// take tens of milliseconds, and doing that from the hotkey handler made the overlay late.
nonisolated final class AudioGraph: @unchecked Sendable {
    private let queue = DispatchQueue(label: "echo.audio.graph", qos: .userInitiated)
    /// Buffers leave the HAL IO thread right away and are resampled and metered here.
    private let processQueue = DispatchQueue(label: "echo.audio.process", qos: .userInteractive)
    private let collector: AudioSampleCollector
    private let resampler: StreamingResampler
    private let levelClock: LevelPublishClock
    private let rmsScratch: RMSScratch
    private let firstBufferAt = OSAllocatedUnfairLock(initialState: CFAbsoluteTime?.none)

    /// Queue-confined.
    private var device: AudioInputDevices.Device?
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false
    private var resamplerRate: Double = 0
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

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

        queue.async {
            // Default input swaps and devices coming or going (AirPods connecting, a USB mic
            // unplugged) can change which mic echo should use.
            self.systemListeners = self.addListeners(
                on: AudioObjectID(kAudioObjectSystemObject),
                selectors: [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices]
            )
        }
    }

    deinit {
        for (address, block) in systemListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
    }

    /// Fire-and-forget warm: picks the device and registers the IOProc without starting IO.
    /// Safe to call repeatedly (launch, wake, device change).
    func prepare() {
        queue.async {
            try? self.configureLocked(warmOnly: true)
        }
    }

    /// Returns true if the device actually had to be started, false if it was already running.
    @discardableResult
    func start() async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            queue.async {
                do {
                    continuation.resume(returning: try self.startLocked())
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
                self.stopLocked()
                // A headset mic is only used when it is the sole input. Unregister it so
                // nothing holds it between takes.
                if self.device?.isBluetooth == true {
                    self.releaseDeviceLocked()
                }
                continuation.resume()
            }
        }
    }

    func teardown() {
        queue.sync {
            stopLocked()
            releaseDeviceLocked()
        }
    }

    /// Re-picks the device and re-reads its format after sleep or a route change.
    ///
    /// Without this, a sample-rate change leaves the resampler set up for the old format, it
    /// rejects every buffer, and the take comes back empty.
    func refresh() {
        queue.async {
            self.refreshLocked()
        }
    }

    func markTakeStart() {
        firstBufferAt.withLock { $0 = nil }
    }

    /// Milliseconds from `reference` to the first captured buffer, once one has arrived.
    /// Read after the take; the IO thread only stores a timestamp.
    func firstBufferDelay(since reference: CFAbsoluteTime) -> Double? {
        guard let stamp = firstBufferAt.withLock({ $0 }) else { return nil }
        return (stamp - reference) * 1000
    }

    // MARK: - Queue-confined

    private func refreshLocked() {
        // Ask the sink too: a device that vanished mid-take may already have stopped itself.
        let wasRunning = running || collector.isCapturing
        stopLocked()
        releaseDeviceLocked()
        if wasRunning {
            do {
                _ = try startLocked()
            } catch {
                Latency.note("capture restart after device change failed: \(error.localizedDescription)")
            }
        } else {
            try? configureLocked(warmOnly: true)
        }
    }

    private func startLocked() throws -> Bool {
        try configureLocked(warmOnly: false)
        guard let device, let ioProcID else { throw Self.micUnavailable }
        if running { return false }
        let status = AudioDeviceStart(device.id, ioProcID)
        guard status == noErr else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Couldn’t start the microphone (\(status))."]
            )
        }
        running = true
        return true
    }

    private func stopLocked() {
        guard running, let device, let ioProcID else {
            running = false
            return
        }
        AudioDeviceStop(device.id, ioProcID)
        running = false
    }

    /// Makes sure an IOProc is registered on the right device with a matching resampler.
    /// `warmOnly` skips Bluetooth devices: touching a headset outside a take is what flips it
    /// into its call profile.
    private func configureLocked(warmOnly: Bool) throws {
        guard let target = AudioInputDevices.captureDevice() else { throw Self.micUnavailable }
        if target == device, ioProcID != nil { return }
        if warmOnly, target.isBluetooth { return }

        stopLocked()
        releaseDeviceLocked()

        guard let stream = AudioInputDevices.inputStreamFormat(target.id),
              stream.mFormatID == kAudioFormatLinearPCM,
              stream.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              stream.mBitsPerChannel == 32,
              stream.mSampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: stream.mSampleRate, channels: 1)
        else { throw Self.micUnavailable }

        processQueue.sync {
            resampler.prepare(inputFormat: format)
        }

        var procID: AudioDeviceIOProcID?
        let block = makeIOBlock(format: format)
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, target.id, nil, block)
        guard status == noErr, let procID else { throw Self.micUnavailable }

        ioProcID = procID
        device = target
        // Sample-rate or stream changes on the device itself, and the device disappearing.
        deviceListeners = addListeners(
            on: target.id,
            selectors: [
                kAudioDevicePropertyNominalSampleRate,
                kAudioDevicePropertyStreamConfiguration,
                kAudioDevicePropertyDeviceIsAlive,
            ]
        )
        Latency.note(
            "capture device: \(target.name) @ \(Int(stream.mSampleRate)) Hz\(target.isBluetooth ? " (Bluetooth, no other mic)" : "")"
        )
    }

    private func releaseDeviceLocked() {
        if let device {
            for (address, block) in deviceListeners {
                var address = address
                AudioObjectRemovePropertyListenerBlock(device.id, &address, queue, block)
            }
            if let ioProcID {
                AudioDeviceDestroyIOProcID(device.id, ioProcID)
            }
        }
        deviceListeners = []
        ioProcID = nil
        device = nil
        running = false
    }

    private func addListeners(
        on object: AudioObjectID,
        selectors: [AudioObjectPropertySelector]
    ) -> [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] {
        selectors.compactMap { selector in
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleDeviceChangeLocked()
            }
            guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
            return (address, block)
        }
    }

    /// Listener blocks are delivered on `queue`.
    private func handleDeviceChangeLocked() {
        let wanted = AudioInputDevices.captureDevice()
        // Device list churn that doesn't change the chosen mic (AirPods connecting while the
        // built-in mic stays selected) needs nothing, and restarting would drop audio mid-take.
        if let wanted, wanted == device,
           let stream = AudioInputDevices.inputStreamFormat(wanted.id),
           stream.mSampleRate == resamplerRate {
            return
        }
        Latency.note("audio device change — re-picking microphone")
        refreshLocked()
    }

    /// Runs on the HAL IO thread. Copies channel 0 out and hands it to `processQueue`.
    private func makeIOBlock(format: AVAudioFormat) -> AudioDeviceIOBlock {
        resamplerRate = format.sampleRate
        let process = processQueue
        let handle = makeBufferHandler()
        return { _, inputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let first = buffers.first, let data = first.mData else { return }
            let channels = Int(max(first.mNumberChannels, 1))
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let destination = buffer.floatChannelData?[0]
            else { return }

            let source = data.assumingMemoryBound(to: Float.self)
            if channels == 1 {
                destination.update(from: source, count: frames)
            } else {
                var zero: Float = 0
                vDSP_vsadd(source, vDSP_Stride(channels), &zero, destination, 1, vDSP_Length(frames))
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            // Fresh buffer, never touched again on this thread.
            nonisolated(unsafe) let owned = buffer
            process.async { handle(owned) }
        }
    }

    private func makeBufferHandler() -> @Sendable (AVAudioPCMBuffer) -> Void {
        let sink = collector
        let resampler = resampler
        let clock = levelClock
        let scratch = rmsScratch
        let stamp = firstBufferAt
        let window = LevelWindow()
        return { buffer in
            if let converted = resampler.convert(buffer) {
                sink.append(converted: converted)
            }

            guard sink.isCapturing else {
                window.reset()
                return
            }

            stamp.withLock { existing in
                if existing == nil { existing = CFAbsoluteTimeGetCurrent() }
            }

            // The wave scrolls one bar per published level, so the publish rate *is* the wave
            // speed. The HAL delivers ~10 ms buffers; fold them into 100 ms windows, the cadence
            // the overlay was tuned against.
            guard let (rms, peak) = window.add(buffer, scratch: scratch) else { return }
            clock.store(AudioGraph.level(rms: rms, peak: peak))
        }
    }

    private static let micUnavailable = NSError(
        domain: "EchoAudio",
        code: 1,
        userInfo: [
            NSLocalizedDescriptionKey: "Microphone isn’t available. Pick a mic in System Settings → Sound."
        ]
    )

    nonisolated fileprivate static func measure(_ buffer: AVAudioPCMBuffer, scratch: RMSScratch) -> (rms: Float, peak: Float) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return (0, 0) }

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
            return (0, 0)
        }
        return (rms, peak)
    }

    nonisolated private static func level(rms: Float, peak: Float) -> Float {
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

/// Accumulates short HAL buffers into fixed-length level windows. Confined to the process queue.
nonisolated final class LevelWindow: @unchecked Sendable {
    static let duration: Double = 0.1

    private var sumOfSquares: Float = 0
    private var peak: Float = 0
    private var frames = 0

    /// Returns the window's RMS and peak once it has filled, otherwise nil.
    func add(_ buffer: AVAudioPCMBuffer, scratch: RMSScratch) -> (Float, Float)? {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return nil }
        let stats = AudioGraph.measure(buffer, scratch: scratch)
        sumOfSquares += stats.rms * stats.rms * Float(count)
        peak = max(peak, stats.peak)
        frames += count

        guard Double(frames) >= buffer.format.sampleRate * Self.duration else { return nil }
        let result = ((sumOfSquares / Float(frames)).squareRoot(), peak)
        reset()
        return result
    }

    func reset() {
        sumOfSquares = 0
        peak = 0
        frames = 0
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
        var energy: Float = 0
        var pending = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

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
            $0.energy = 0
            $0.pending = false
        }
    }
}
