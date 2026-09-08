import AVFoundation
import Accelerate
import os

@MainActor
final class AudioEngineService {
    private let engine = AVAudioEngine()
    private let collector = AudioSampleCollector()
    private let resampler = StreamingResampler()
    private var history = [Float](repeating: 0, count: OverlayMetrics.barCount)
    private var historyWrite = 0
    private var envelope: Float = 0
    private let levelClock = LevelPublishClock()
    private let rmsScratch = RMSScratch()
    private var tapInstalled = false

    var sampleCollector: AudioSampleCollector { collector }

    func prepareGraph() throws {
        try installTapIfNeeded()
        prepareResamplerIfIdle()
        engine.prepare()
    }

    func beginCapture(keepSamplesInMemory: Bool = true) throws {
        collector.beginSession(keepSamplesInMemory: keepSamplesInMemory)
        resetHistory()
        envelope = 0
        levelClock.reset()
        prepareResamplerIfIdle()
        try ensureRunning()
    }

    @discardableResult
    func endCapture() async -> AudioCaptureSnapshot {
        let snapshot = await collector.endSession()
        resetHistory()
        envelope = 0
        levelClock.reset()
        releaseMicrophone()
        return snapshot
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
        removeTap()
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
        resampler.reset()
        resetHistory()
        Task { await collector.reset() }
    }

    private func resetHistory() {
        history = [Float](repeating: 0, count: OverlayMetrics.barCount)
        historyWrite = 0
    }

    private func releaseMicrophone() {
        if engine.isRunning {
            engine.stop()
        }
    }

    private func ensureRunning() throws {
        try installTapIfNeeded()
        if engine.isRunning { return }
        prepareResamplerIfIdle()
        engine.prepare()
        try engine.start()
    }

    private func prepareResamplerIfIdle() {
        guard !engine.isRunning else { return }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return }
        resampler.prepare(inputFormat: format)
    }

    private func installTapIfNeeded() throws {
        if tapInstalled { return }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw NSError(
                domain: "EchoAudio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone isn’t available. Pick a mic in System Settings → Sound."]
            )
        }

        let sink = collector
        let resampler = resampler
        let clock = levelClock
        let scratch = rmsScratch
        resampler.prepare(inputFormat: format)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            if let converted = resampler.convert(buffer) {
                sink.append(converted: converted)
            }

            guard sink.isCapturing else { return }

            let now = CFAbsoluteTimeGetCurrent()
            guard now - clock.last >= 1.0 / 24.0 else { return }
            clock.last = now
            clock.store(AudioEngineService.rmsEnergy(buffer: buffer, scratch: scratch))
        }
        tapInstalled = true
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

    private func removeTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
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

nonisolated private final class LevelPublishClock: @unchecked Sendable {
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
