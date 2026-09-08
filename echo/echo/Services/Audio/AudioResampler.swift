import AVFoundation
import Accelerate

enum AudioResampler {
    static let targetSampleRate: Double = 16_000

    static func mono16kFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    /// Converts any PCM buffer to 16 kHz mono Float32. Returns `nil` if conversion fails.
    static func convertToMono16k(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = mono16kFormat()
        if buffer.format.sampleRate == target.sampleRate,
           buffer.format.channelCount == 1,
           buffer.format.commonFormat == .pcmFormatFloat32 {
            return buffer
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: target) else {
            return nil
        }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = max(AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32, 1)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil, output.frameLength > 0 else {
            return nil
        }
        return output
    }

    static func pcmBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        let format = mono16kFormat()
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              )
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress, let dest = buffer.floatChannelData?[0] else { return }
            dest.update(from: base, count: samples.count)
        }
        return buffer
    }

    static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    static func int16PCM(from samples: [Float]) -> Data {
        let count = vDSP_Length(samples.count)
        var clipped = [Float](repeating: 0, count: samples.count)
        var low: Float = -1
        var high: Float = 1
        vDSP_vclip(samples, 1, &low, &high, &clipped, 1, count)
        var scale = Float(Int16.max)
        vDSP_vsmul(clipped, 1, &scale, &clipped, 1, count)
        var ints = [Int16](repeating: 0, count: samples.count)
        vDSP_vfix16(clipped, 1, &ints, 1, count)
        return ints.withUnsafeBytes { Data($0) }
    }

    static func wavData(from samples: [Float], sampleRate: Int = 16_000) -> Data {
        let pcm = int16PCM(from: samples)
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: string.utf8) }
        func append<T>(_ value: T) {
            var v = value
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        let byteRate = UInt32(sampleRate * 2)
        append("RIFF")
        append(UInt32(36 + pcm.count).littleEndian)
        append("WAVE")
        append("fmt ")
        append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian) // PCM
        append(UInt16(1).littleEndian) // mono
        append(UInt32(sampleRate).littleEndian)
        append(byteRate.littleEndian)
        append(UInt16(2).littleEndian)
        append(UInt16(16).littleEndian)
        append("data")
        append(UInt32(pcm.count).littleEndian)
        data.append(pcm)
        return data
    }
}

/// Owned by the audio tap thread after `prepare`. Never install a converter on the tap.
nonisolated final class StreamingResampler: @unchecked Sendable {
    private let outputFormat = AudioResampler.mono16kFormat()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputBuffer: AVAudioPCMBuffer?
    private var inputConsumed = false

    /// Call only while the engine is idle (before `start`, after `stop`).
    func prepare(inputFormat: AVAudioFormat) {
        installConverter(from: inputFormat)
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.sampleRate == outputFormat.sampleRate,
           buffer.format.channelCount == 1,
           buffer.format.commonFormat == .pcmFormatFloat32 {
            return buffer
        }

        guard let converter, inputFormat == buffer.format else { return nil }
        guard let output = outputBuffer else { return nil }
        let ratio = outputFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let needed = max(AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64, 1)
        guard output.frameCapacity >= needed else { return nil }
        output.frameLength = 0

        inputConsumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { [self] _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    func reset() {
        converter = nil
        inputFormat = nil
        outputBuffer = nil
        inputConsumed = false
    }

    private func installConverter(from format: AVAudioFormat) {
        converter = AVAudioConverter(from: format, to: outputFormat)
        converter?.primeMethod = .normal
        inputFormat = format
        let ratio = outputFormat.sampleRate / max(format.sampleRate, 1)
        let capacity = max(AVAudioFrameCount(8_192 * ratio) + 64, 8_192)
        outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
    }
}
