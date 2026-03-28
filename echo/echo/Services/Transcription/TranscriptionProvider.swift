import AVFoundation

protocol TranscriptionProvider: AnyObject, Sendable {
    func startStreaming() async throws
    func appendBuffer(_ buffer: AVAudioPCMBuffer)
    func stopStreaming() async throws -> String
    var partialTranscript: AsyncStream<String> { get }
}
