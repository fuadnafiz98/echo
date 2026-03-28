import AVFoundation

@MainActor
final class TranscriptionService {
    private var activeProvider: (any TranscriptionProvider)?
    private var partialTask: Task<Void, Never>?

    var onPartialTranscript: ((String) -> Void)?

    func startStreaming(providerType: TranscriptionProviderType) async throws {
        let provider = makeProvider(for: providerType)
        activeProvider = provider

        try await provider.startStreaming()

        // Listen for partial transcripts
        partialTask = Task { [weak self] in
            for await text in provider.partialTranscript {
                guard !Task.isCancelled else { break }
                self?.onPartialTranscript?(text)
            }
        }
    }

    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        activeProvider?.appendBuffer(buffer)
    }

    func stopStreaming() async throws -> String {
        partialTask?.cancel()
        partialTask = nil

        guard let provider = activeProvider else {
            return ""
        }

        let result = try await provider.stopStreaming()
        activeProvider = nil
        return result
    }

    private func makeProvider(for type: TranscriptionProviderType) -> any TranscriptionProvider {
        switch type {
        case .apple:
            AppleSTTProvider()
        case .deepgram:
            DeepgramProvider()
        case .mistral:
            MistralProvider()
        case .parakeet:
            ParakeetProvider()
        }
    }
}
