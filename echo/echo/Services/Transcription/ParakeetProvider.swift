import AVFoundation

final class ParakeetProvider: TranscriptionProvider, @unchecked Sendable {
    private var partialContinuation: AsyncStream<String>.Continuation?
    private var accumulatedBuffers: [AVAudioPCMBuffer] = []

    var partialTranscript: AsyncStream<String> {
        AsyncStream { [weak self] continuation in
            self?.partialContinuation = continuation
        }
    }

    func startStreaming() async throws {
        // TODO: Implement local ParakeetTDT inference
        // Download model from HuggingFace: nvidia/parakeet-tdt-0.6b-v2
        // Run via ONNX Runtime or MLX
        throw TranscriptionError.recognizerUnavailable
    }

    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        accumulatedBuffers.append(buffer)
    }

    func stopStreaming() async throws -> String {
        partialContinuation?.finish()
        partialContinuation = nil
        accumulatedBuffers.removeAll()
        return ""
    }
}
