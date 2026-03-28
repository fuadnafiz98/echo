import AVFoundation

final class DeepgramProvider: TranscriptionProvider, @unchecked Sendable {
    private var partialContinuation: AsyncStream<String>.Continuation?

    var partialTranscript: AsyncStream<String> {
        AsyncStream { [weak self] continuation in
            self?.partialContinuation = continuation
        }
    }

    func startStreaming() async throws {
        // TODO: Implement WebSocket connection to wss://api.deepgram.com/v1/listen
        throw TranscriptionError.recognizerUnavailable
    }

    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        // TODO: Send audio data over WebSocket
    }

    func stopStreaming() async throws -> String {
        partialContinuation?.finish()
        partialContinuation = nil
        return ""
    }
}
