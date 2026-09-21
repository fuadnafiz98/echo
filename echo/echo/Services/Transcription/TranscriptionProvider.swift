import AVFoundation

nonisolated protocol TranscriptionProvider: AnyObject, Sendable {
    func startStreaming() async throws
    func stopStreaming() async throws -> String
    /// Abandon the take without producing a transcript. Must release any streaming machinery.
    func cancelStreaming() async
    var partialTranscript: AsyncStream<String> { get }
}

extension TranscriptionProvider {
    func cancelStreaming() async {}
}

nonisolated protocol LiveAudioConsumer: AnyObject, Sendable {
    func consumeLiveBuffer(_ buffer: AVAudioPCMBuffer)
}

/// Consumes audio as it is captured, so that at stop only the tail is left to process.
///
/// Buffers arrive on the collector's IO queue in ~256 ms chunks of 16 kHz mono float, and each
/// one is freshly allocated, so the consumer may hold it. This is deliberately not
/// ``LiveAudioConsumer``: that one fires on the CoreAudio tap with a reused buffer.
nonisolated protocol StreamingAudioConsumer: AnyObject, Sendable {
    func consumeStreamingBuffer(_ buffer: AVAudioPCMBuffer)
}

nonisolated protocol BatchAudioConsumer: AnyObject, Sendable {
    /// Receives the capture, not a decoded array: a spilled recording is only read back if the
    /// provider actually falls back to transcribing the whole take.
    func consumeCapture(_ capture: AudioCaptureSnapshot)
}

nonisolated protocol FileAudioConsumer: AnyObject, Sendable {
    func consumeFile(_ url: URL)
}

nonisolated enum TranscriptionError: LocalizedError, Sendable {
    case notAuthorized
    case microphoneDenied
    case recognizerUnavailable
    case modelNotDownloaded
    case noResult
    case missingAPIKey
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Speech recognition is not authorized. Enable it in System Settings → Privacy & Security → Speech Recognition."
        case .microphoneDenied:
            "Microphone access was denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .recognizerUnavailable:
            "The selected speech engine is unavailable."
        case .modelNotDownloaded:
            "This model is not downloaded yet. Open Settings → Models and download it first."
        case .noResult:
            "No transcription result received."
        case .missingAPIKey:
            "Add an API key for this provider in Settings."
        case .network(let message):
            message
        }
    }
}
