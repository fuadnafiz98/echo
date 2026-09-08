import Foundation
import MLXLLM
import MLXLMCommon

/// Runs S1-mini by Superwhisper after speech recognition.
actor S1MiniEngine {
    static let shared = S1MiniEngine()

    private var container: ModelContainer?
    private var folder: URL?
    private var loadEpoch = 0
    private var inFlight: Task<Void, Error>?
    private var inFlightFolder: URL?

    var isReady: Bool { container != nil }

    func load(from folder: URL) async throws {
        if container != nil, self.folder == folder { return }

        if let inFlight, inFlightFolder == folder {
            try await inFlight.value
            if container != nil, self.folder == folder { return }
            return
        }

        inFlight?.cancel()
        loadEpoch += 1
        let epoch = loadEpoch
        inFlightFolder = folder
        let work = Task<Void, Error> {
            try await self.performLoad(folder: folder, epoch: epoch)
        }
        inFlight = work

        do {
            try await work.value
            if epoch == loadEpoch {
                inFlight = nil
            }
        } catch {
            if epoch == loadEpoch {
                inFlight = nil
            }
            throw error
        }
    }

    func unload() {
        loadEpoch += 1
        inFlight?.cancel()
        inFlight = nil
        inFlightFolder = nil
        container = nil
        folder = nil
    }

    private func performLoad(folder: URL, epoch: Int) async throws {
        let configuration = ModelConfiguration(directory: folder)
        let loaded = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
        guard epoch == loadEpoch else { return }
        container = loaded
        self.folder = folder
    }

    func prewarmFromPresence() async {
        guard let folder = LocalModelPresence.folder(for: .s1Mini) else { return }
        try? await load(from: folder)
    }

    func normalize(_ transcript: String, context: String) async throws -> String {
        let container = try await loadedContainer()
        let maxTokens = min(512, max(64, transcript.count / 3 + 48))
        let session = ChatSession(
            container,
            instructions: Self.systemPrompt,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0),
            additionalContext: ["enable_thinking": false]
        )
        let user = "[Styling: semi-formal] [Structure: prose] [Context: \(context)]\n\(transcript)"
        let raw = try await session.respond(to: user)
        return Self.sanitize(raw)
    }

    private func loadedContainer() async throws -> ModelContainer {
        if let container { return container }
        if folder == nil {
            folder = LocalModelPresence.folder(for: .s1Mini)
        }
        guard let folder else {
            throw TranscriptionError.modelNotDownloaded
        }
        try await load(from: folder)
        guard let container else { throw TranscriptionError.modelNotDownloaded }
        return container
    }

    static let systemPrompt = """
        You are a text normalizer for speech-to-text transcripts. The input begins \
        with a control line specifying the styling, structure, and context settings; \
        clean the transcript to match those settings and output only the cleaned text.
        """

    private static func sanitize(_ raw: String) -> String {
        var text = raw
        if let think = text.range(of: "</think>") {
            text = String(text[think.upperBound...])
        }
        text = text.replacingOccurrences(of: "<think>", with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
