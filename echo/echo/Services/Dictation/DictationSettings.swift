import AppKit
import Foundation

nonisolated enum CleanupEngine: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case appleIntelligence
    case s1Mini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .appleIntelligence: "Apple Intelligence"
        case .s1Mini: "S1-mini by Superwhisper"
        }
    }
}

struct TextReplacement: Identifiable, Codable, Hashable {
    var id: UUID
    var heard: String
    var written: String

    init(id: UUID = UUID(), heard: String, written: String) {
        self.id = id
        self.heard = heard
        self.written = written
    }
}

/// Persisted words and replacement rules. Keep the speech-hint list short.
@Observable @MainActor
final class DictationSettings {
    static let shared = DictationSettings()

    var vocabulary: [String]
    var replacements: [TextReplacement]
    var useFrontmostProject: Bool {
        didSet { persist() }
    }
    var cleanupEngine: CleanupEngine {
        didSet { persist() }
    }
    var stripFillers: Bool {
        didSet { persist() }
    }
    var restoreClipboard: Bool {
        didSet { persist() }
    }
    var showMenuBar: Bool {
        didSet { persist() }
    }
    var showInDock: Bool {
        didSet {
            persist()
            AppChrome.applyDockVisibility(showInDock)
        }
    }

    var polishTranscript: Bool { cleanupEngine != .off }

    static let maxHintTerms = 80
    static let showMenuBarKey = "showMenuBar"
    static let showInDockKey = "showInDock"

    private let fileURL: URL

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Echo", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("dictation.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            vocabulary = decoded.vocabulary
            replacements = decoded.replacements
            useFrontmostProject = decoded.useFrontmostProject
            stripFillers = decoded.stripFillers ?? true
            restoreClipboard = decoded.restoreClipboard ?? true
            showMenuBar = decoded.showMenuBar
                ?? UserDefaults.standard.object(forKey: Self.showMenuBarKey) as? Bool
                ?? true
            showInDock = decoded.showInDock
                ?? UserDefaults.standard.object(forKey: Self.showInDockKey) as? Bool
                ?? Self.defaultShowInDock
            if let engine = decoded.cleanupEngine {
                cleanupEngine = engine
            } else if decoded.polishTranscript {
                cleanupEngine = TranscriptCleaner.appleIntelligenceIsAvailable ? .appleIntelligence : .off
            } else if TranscriptCleaner.appleIntelligenceIsAvailable {
                cleanupEngine = .appleIntelligence
            } else {
                cleanupEngine = .off
            }
            if decoded.cleanupEngine == nil || decoded.showMenuBar == nil || decoded.showInDock == nil {
                persist()
            }
            expandProductNames()
        } else {
            vocabulary = []
            replacements = Self.defaultReplacements
            useFrontmostProject = true
            cleanupEngine = TranscriptCleaner.appleIntelligenceIsAvailable ? .appleIntelligence : .off
            stripFillers = true
            restoreClipboard = true
            showMenuBar = UserDefaults.standard.object(forKey: Self.showMenuBarKey) as? Bool ?? true
            showInDock = UserDefaults.standard.object(forKey: Self.showInDockKey) as? Bool ?? Self.defaultShowInDock
        }
    }

    func addVocabulary(_ raw: String) {
        let parts = raw
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for word in parts {
            if !vocabulary.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }),
               vocabulary.count < Self.maxHintTerms {
                vocabulary.append(word)
            }
            addSpokenReplacements(for: word)
        }
        persist()
    }

    func addSpokenReplacements(for written: String) {
        for heard in SpokenForms.expansions(for: written) {
            guard SpokenForms.isPersistableSpokenForm(heard) else { continue }
            guard !replacements.contains(where: { $0.heard.caseInsensitiveCompare(heard) == .orderedSame }) else {
                continue
            }
            replacements.append(TextReplacement(heard: heard, written: written))
        }
        rememberHint(written)
    }

    private func expandProductNames() {
        let beforeRules = replacements.count
        let beforeHints = vocabulary.count
        for rule in Array(replacements) where looksLikeProductName(rule.written) {
            addSpokenReplacements(for: rule.written)
        }
        if replacements.count != beforeRules || vocabulary.count != beforeHints {
            persist()
        }
    }

    private func rememberHint(_ word: String) {
        guard looksLikeProductName(word) else { return }
        guard !vocabulary.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { return }
        guard vocabulary.count < Self.maxHintTerms else { return }
        vocabulary.append(word)
    }

    private func looksLikeProductName(_ word: String) -> Bool {
        word.contains("-") || word.contains(where: \.isNumber)
    }

    func removeVocabulary(_ word: String) {
        vocabulary.removeAll { $0 == word }
        persist()
    }

    func addReplacement(heard: String, written: String) {
        let from = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty else { return }
        replacements.removeAll { $0.heard.caseInsensitiveCompare(from) == .orderedSame }
        replacements.append(TextReplacement(heard: from, written: to))
        addSpokenReplacements(for: to)
        persist()
    }

    func removeReplacement(id: UUID) {
        replacements.removeAll { $0.id == id }
        persist()
    }

    func persist() {
        let payload = Payload(
            vocabulary: vocabulary,
            replacements: replacements,
            useFrontmostProject: useFrontmostProject,
            polishTranscript: cleanupEngine != .off,
            cleanupEngine: cleanupEngine,
            stripFillers: stripFillers,
            restoreClipboard: restoreClipboard,
            showMenuBar: showMenuBar,
            showInDock: showInDock
        )
        UserDefaults.standard.set(showMenuBar, forKey: Self.showMenuBarKey)
        UserDefaults.standard.set(showInDock, forKey: Self.showInDockKey)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private struct Payload: Codable {
        var vocabulary: [String]
        var replacements: [TextReplacement]
        var useFrontmostProject: Bool
        var polishTranscript: Bool
        var cleanupEngine: CleanupEngine?
        var stripFillers: Bool?
        var restoreClipboard: Bool?
        var showMenuBar: Bool?
        var showInDock: Bool?
    }

    /// Shipping Echo is `LSUIElement` (accessory). Match a regular app if the Dock icon is already showing.
    static var defaultShowInDock: Bool {
        NSApplication.shared.activationPolicy() == .regular
    }

    private static let defaultReplacements: [TextReplacement] = [
        TextReplacement(heard: "at sign", written: "@"),
        TextReplacement(heard: "dot com", written: ".com"),
        TextReplacement(heard: "dot net", written: ".net"),
        TextReplacement(heard: "dot org", written: ".org"),
        TextReplacement(heard: "dot io", written: ".io"),
        TextReplacement(heard: "hashtag", written: "#"),
        TextReplacement(heard: "slash", written: "/"),
        TextReplacement(heard: "underscore", written: "_"),
    ]
}
