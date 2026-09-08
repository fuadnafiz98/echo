import AVFoundation

@MainActor
final class TranscriptionService {
    private var activeProvider: (any TranscriptionProvider)?
    private var collector: AudioSampleCollector?
    private var pendingHints: [String] = []

    func prepare(
        providerType: TranscriptionProviderType,
        whisperVariant: WhisperVariant,
        parakeetVariant: ParakeetVariant,
        collector: AudioSampleCollector,
        vocabularyHints: [String] = []
    ) async throws {
        self.collector = collector
        let provider = makeProvider(
            for: providerType,
            whisperVariant: whisperVariant,
            parakeetVariant: parakeetVariant
        )
        let hints = vocabularyHints.isEmpty ? pendingHints : vocabularyHints
        if !hints.isEmpty {
            pendingHints = hints
        }
        applyHints(hints, to: provider)
        activeProvider = provider

        if let live = provider as? LiveAudioConsumer {
            collector.setLiveHandler { [weak live] buffer in
                live?.consumeLiveBuffer(buffer)
            }
        }

        try await Task.detached(priority: .userInitiated) {
            try await provider.startStreaming()
        }.value
    }

    func setVocabularyHints(_ hints: [String]) {
        pendingHints = hints
        if let provider = activeProvider {
            applyHints(hints, to: provider)
        }
    }

    func finishAndTranscribe(snapshot: AudioCaptureSnapshot) async throws -> String {
        guard let provider = activeProvider else { return "" }
        collector?.setLiveHandler(nil)

        if let fileConsumer = provider as? FileAudioConsumer, let url = snapshot.fileURL {
            fileConsumer.consumeFile(url)
        }
        let needsRAM = !(provider is AppleSTTProvider) || snapshot.fileURL == nil
        if needsRAM, let batch = provider as? BatchAudioConsumer {
            batch.consumeSamples(snapshot.samples)
        }

        let leftover = collector
        let result: String
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try await provider.stopStreaming()
            }.value
        } catch {
            await leftover?.cleanupRecordingFile()
            activeProvider = nil
            collector = nil
            pendingHints = []
            throw error
        }

        activeProvider = nil
        collector = nil
        pendingHints = []
        if let leftover {
            let generation = leftover.sessionGeneration
            Task(priority: .utility) {
                await leftover.cleanupRecordingFile(expectedGeneration: generation)
            }
        }
        return result
    }

    func cancel() async {
        collector?.setLiveHandler(nil)
        await collector?.cleanupRecordingFile()
        activeProvider = nil
        collector = nil
        pendingHints = []
    }

    private func applyHints(_ hints: [String], to provider: any TranscriptionProvider) {
        if let apple = provider as? AppleSTTProvider {
            apple.setVocabularyHints(hints)
        }
        if let whisper = provider as? WhisperKitProvider {
            whisper.setVocabularyHints(hints)
        }
    }

    private func makeProvider(
        for type: TranscriptionProviderType,
        whisperVariant: WhisperVariant,
        parakeetVariant: ParakeetVariant
    ) -> any TranscriptionProvider {
        switch type {
        case .apple:
            AppleSTTProvider()
        case .whisper:
            WhisperKitProvider(variant: whisperVariant)
        case .parakeet:
            ParakeetProvider(variant: parakeetVariant)
        case .deepgram:
            DeepgramProvider()
        case .mistral:
            MistralProvider()
        }
    }
}
