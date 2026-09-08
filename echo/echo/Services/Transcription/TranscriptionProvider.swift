import AVFoundation

nonisolated protocol TranscriptionProvider: AnyObject, Sendable {
    func startStreaming() async throws
    func stopStreaming() async throws -> String
    var partialTranscript: AsyncStream<String> { get }
}

nonisolated protocol LiveAudioConsumer: AnyObject, Sendable {
    func consumeLiveBuffer(_ buffer: AVAudioPCMBuffer)
}

nonisolated protocol BatchAudioConsumer: AnyObject, Sendable {
    func consumeSamples(_ samples: [Float])
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
