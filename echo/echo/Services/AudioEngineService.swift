import AVFoundation
import Accelerate

@MainActor
final class AudioEngineService {
    private let engine = AVAudioEngine()
    private var smoothedLevels: [Float] = Array(repeating: 0, count: 16)
    private var lastLevelUpdateTime: CFAbsoluteTime = 0
    private let levelUpdateInterval: CFAbsoluteTime = 1.0 / 30.0 // 30 fps cap

    var onAudioLevels: (([Float]) -> Void)?
    // Called on the audio thread — do NOT dispatch inside this callback
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start() throws {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }

            // Forward buffer to transcription synchronously on audio thread
            self.onAudioBuffer?(buffer)

            // Throttle UI level updates to 30fps
            let now = CFAbsoluteTimeGetCurrent()
            guard (now - self.lastLevelUpdateTime) >= self.levelUpdateInterval else { return }
            self.lastLevelUpdateTime = now

            let levels = self.computeLevels(buffer: buffer, barCount: 16)

            Task { @MainActor [weak self] in
                guard let self else { return }
                for i in 0..<16 {
                    let raw  = levels[i]
                    let prev = self.smoothedLevels[i]
                    // Fast attack so bars snap up instantly; slow release so they fall gracefully
                    let alpha: Float = raw > prev ? 0.80 : 0.14
                    self.smoothedLevels[i] = prev * (1 - alpha) + raw * alpha
                }
                self.onAudioLevels?(self.smoothedLevels)
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        smoothedLevels = Array(repeating: 0, count: 16)
        lastLevelUpdateTime = 0
    }

    nonisolated private func computeLevels(buffer: AVAudioPCMBuffer, barCount: Int) -> [Float] {
        guard let channelData = buffer.floatChannelData else {
            return Array(repeating: 0, count: barCount)
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return Array(repeating: 0, count: barCount) }

        let data = channelData[0]
        let segmentSize = max(frameCount / barCount, 1)

        var levels = [Float](repeating: 0, count: barCount)
        for i in 0..<barCount {
            let offset = i * segmentSize
            let count = min(segmentSize, frameCount - offset)
            guard count > 0 else { continue }
            var rms: Float = 0
            vDSP_rmsqv(data.advanced(by: offset), 1, &rms, vDSP_Length(count))
            // Noise gate: ignore ambient noise floor; power curve boosts mid-range speech
            let amplified = pow(min(rms * 22.0, 1.0), 0.45)
            levels[i] = amplified < 0.06 ? 0 : amplified
        }
        return levels
    }
}
