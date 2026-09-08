import AVFoundation
import Foundation

nonisolated final class DeepgramProvider: TranscriptionProvider, BatchAudioConsumer, @unchecked Sendable {
    private var samples: [Float] = []
    private var partialContinuation: AsyncStream<String>.Continuation?

    var partialTranscript: AsyncStream<String> {
        AsyncStream { [weak self] continuation in
            self?.partialContinuation = continuation
        }
    }

    func startStreaming() async throws {
        samples = []
        let key = UserDefaults.standard.string(forKey: "deepgramAPIKey") ?? ""
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

        let key = UserDefaults.standard.string(forKey: "deepgramAPIKey") ?? ""
        guard !key.isEmpty else { throw TranscriptionError.missingAPIKey }
        guard !samples.isEmpty else { return "" }

        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-2"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = AudioResampler.wavData(from: samples)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Deepgram transcription failed."
            throw TranscriptionError.network(message)
        }

        let text = Self.parseTranscript(data)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            partialContinuation?.yield(text)
        }
        return text
    }

    private static func parseTranscript(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [String: Any],
              let channels = results["channels"] as? [[String: Any]],
              let alternatives = channels.first?["alternatives"] as? [[String: Any]],
              let transcript = alternatives.first?["transcript"] as? String
        else { return nil }
        return transcript
    }
}
