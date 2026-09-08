import AVFoundation
import Foundation

nonisolated final class MistralProvider: TranscriptionProvider, BatchAudioConsumer, @unchecked Sendable {
    private var samples: [Float] = []
    private var partialContinuation: AsyncStream<String>.Continuation?

    var partialTranscript: AsyncStream<String> {
        AsyncStream { [weak self] continuation in
            self?.partialContinuation = continuation
        }
    }

    func startStreaming() async throws {
        samples = []
        let key = UserDefaults.standard.string(forKey: "mistralAPIKey") ?? ""
        guard !key.isEmpty else { throw TranscriptionError.missingAPIKey }
    }

    func consumeSamples(_ samples: [Float]) {
        self.samples = samples
    }

    func stopStreaming() async throws -> String {
        defer {
            partialContinuation?.finish()
            partialContinuation = nil
        }

        let key = UserDefaults.standard.string(forKey: "mistralAPIKey") ?? ""
        guard !key.isEmpty else { throw TranscriptionError.missingAPIKey }
        guard !samples.isEmpty else { return "" }

        let wav = AudioResampler.wavData(from: samples)
        let boundary = "EchoBoundary\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(contentsOf: string.utf8) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("voxtral-mini-latest\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Mistral transcription failed."
            throw TranscriptionError.network(message)
        }

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (object?["text"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            partialContinuation?.yield(text)
        }
        return text
    }
}
