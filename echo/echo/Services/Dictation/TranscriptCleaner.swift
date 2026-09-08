import Foundation
import FoundationModels

@Generable
struct CleanedTranscript {
    @Guide(description: "The cleaned transcript only. No quotes, labels, or commentary.")
    var text: String
}

/// Cleans a finished transcript with Apple Intelligence or S1-mini by Superwhisper.
@MainActor
final class TranscriptCleaner {
    static let shared = TranscriptCleaner()

    private var primedSession: LanguageModelSession?
    private var primedSignature: String?

    static var appleIntelligenceIsAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    var s1MiniAvailable: Bool {
        ModelLibrary.shared.isReady(.s1Mini)
    }

    var appleIntelligenceAvailable: Bool {
        Self.appleIntelligenceIsAvailable
    }

    var appleIntelligenceStatus: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            "On this Mac. Rewrites fillers, self-corrections, and spoken numbers. Uses your word list so names like aim2-core stay spelled right."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in System Settings. Siri is not required."
        case .unavailable(.modelNotReady):
            "Apple Intelligence is still downloading on this Mac."
        case .unavailable(.deviceNotEligible):
            "This Mac cannot run Apple Intelligence."
        case .unavailable:
            "Apple Intelligence is not available."
        }
    }

    func prewarm() {
        switch DictationSettings.shared.cleanupEngine {
        case .s1Mini:
            Task.detached {
                await S1MiniEngine.shared.prewarmFromPresence()
            }
        case .appleIntelligence:
            guard refreshAppleSessionIfNeeded() else { return }
            primedSession?.prewarm(promptPrefix: Prompt("Clean this transcript:\n"))
        case .off:
            primedSession = nil
            primedSignature = nil
        }
    }

    func polish(_ text: String, scene: DictationScene, glossary: [String]) async -> String? {
        switch DictationSettings.shared.cleanupEngine {
        case .off:
            return nil
        case .s1Mini:
            guard s1MiniAvailable else { return nil }
            guard let budget = polishBudget(for: text) else { return nil }
            return await withTimeout(budget) {
                try await S1MiniEngine.shared.normalize(text, context: scene.kind.polishContext)
            }
        case .appleIntelligence:
            guard refreshAppleSessionIfNeeded() else { return nil }
            return await polishWithAppleIntelligence(text, scene: scene, glossary: glossary)
        }
    }

    /// Rebuild the Apple Intelligence session when the engine or user glossary changes.
    @discardableResult
    private func refreshAppleSessionIfNeeded() -> Bool {
        guard appleIntelligenceAvailable else {
            primedSession = nil
            primedSignature = nil
            return false
        }
        let glossary = DictationSettings.shared.vocabulary
        let signature = sessionSignature(engine: .appleIntelligence, glossary: glossary)
        if primedSession == nil || primedSignature != signature {
            primedSession = makeSession(glossary: glossary)
            primedSignature = signature
        }
        return primedSession != nil
    }

    private func polishWithAppleIntelligence(
        _ text: String,
        scene: DictationScene,
        glossary: [String]
    ) async -> String? {
        guard let session = primedSession else { return nil }
        let prompt = applePrompt(text: text, scene: scene, glossary: glossary)
        let options = GenerationOptions(
            sampling: .greedy,
            temperature: 0.1,
            maximumResponseTokens: min(2048, max(96, text.count / 3 + 64))
        )
        guard let budget = polishBudget(for: text) else { return nil }
        return await withTimeout(budget) {
            let response = try await session.respond(
                to: prompt,
                generating: CleanedTranscript.self,
                options: options
            )
            let cleaned = response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    private func sessionSignature(engine: CleanupEngine, glossary: [String]) -> String {
        engine.rawValue + "\u{1e}" + glossary.joined(separator: "\u{1f}")
    }

    /// Paste-first budget: 350–900 ms, skip model polish on very long takes.
    private func polishBudget(for text: String) -> Duration? {
        let words = text.split(whereSeparator: \.isWhitespace).count
        if words > 200 { return nil }
        let extra = max(0, words - 24) * 3
        return .milliseconds(min(900, 350 + extra))
    }

    private func makeSession(glossary: [String]) -> LanguageModelSession {
        let model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        return LanguageModelSession(model: model, instructions: appleInstructions(glossary: glossary))
    }

    private func appleInstructions(glossary: [String]) -> String {
        var lines = [
            "You clean a speech-to-text transcript. Return only the cleaned text.",
            "Remove fillers such as um, uh, er, like, you know.",
            "Resolve self-corrections to the last value the speaker landed on.",
            "Write spoken numbers, dates, times, currency, and email addresses in written form.",
            "Keep every sentence the speaker said. Never summarize, shorten, or drop the end of a long take.",
            "Do not add facts, greetings they did not say, or markdown.",
            "Scene and destination details arrive in the prompt. Keep instructions stable across apps.",
        ]
        let names = glossary.prefix(24)
        if !names.isEmpty {
            lines.append("Keep these spellings exactly: " + names.joined(separator: ", ") + ".")
        }
        return lines.joined(separator: " ")
    }

    private func applePrompt(text: String, scene: DictationScene, glossary: [String]) -> String {
        var header = "Clean this transcript.\nContext: \(scene.kind.polishContext). App: \(scene.appName)."
        if let root = scene.projectRoot {
            header += " Project: \(root.lastPathComponent)."
        }
        let names = glossary.prefix(24)
        if !names.isEmpty {
            header += "\nKeep spellings: " + names.joined(separator: ", ")
        }
        return header + "\n\n" + text
    }

    private func withTimeout(
        _ budget: Duration,
        work: @escaping () async throws -> String?
    ) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    let value = try await work()
                    return value?.isEmpty == true ? nil : value
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
