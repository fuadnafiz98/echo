import AVFoundation

final class MistralProvider: TranscriptionProvider, @unchecked Sendable {
    private var partialContinuation: AsyncStream<String>.Continuation?
    private var accumulatedBuffers: [AVAudioPCMBuffer] = []

    var partialTranscript: AsyncStream<String> {
        AsyncStream { [weak self] continuation in
            self?.partialContinuation = continuation
        }
    }

    func startStreaming() async throws {
        // TODO: Implement Mistral REST API transcription
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
