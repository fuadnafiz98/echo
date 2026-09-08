import Foundation

/// Apply-time glossary: user replacements win, then spoken aliases from vocab stems, vocab, and the project lexicon.
enum SpokenAliasTable {
    private static let cacheLock = NSLock()
    private static var cachedKey = ""
    private static var cachedRules: [TextReplacement] = []
    private static let maxGenerated = 200

    static func replacements(
        vocabulary: [String],
        projectTerms: [String],
        userReplacements: [TextReplacement]
    ) -> [TextReplacement] {
        let key = cacheKey(
            vocabulary: vocabulary,
            projectTerms: projectTerms,
            userReplacements: userReplacements
        )
        cacheLock.lock()
        if key == cachedKey, !cachedRules.isEmpty || userReplacements.isEmpty {
            let hit = cachedRules
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        var claimed = Set<String>()
        var generated: [TextReplacement] = []
        generated.reserveCapacity(min(maxGenerated, vocabulary.count * 6 + projectTerms.count * 4))

        for rule in userReplacements where !rule.heard.isEmpty {
            claimed.insert(rule.heard.lowercased())
        }

        func claim(_ heard: String, written: String) {
            guard generated.count < maxGenerated else { return }
            let from = heard.trimmingCharacters(in: .whitespacesAndNewlines)
            let to = written.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty, !to.isEmpty else { return }
            guard from.caseInsensitiveCompare(to) != .orderedSame else { return }
            guard !SpokenForms.isBlockedHeard(from) else { return }
            let token = from.lowercased()
            guard claimed.insert(token).inserted else { return }
            generated.append(TextReplacement(heard: from, written: to))
        }

        var glossary: [String] = []
        var seenTerms = Set<String>()
        func addTerm(_ term: String) {
            let value = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seenTerms.insert(value.lowercased()).inserted else { return }
            glossary.append(value)
        }

        for term in vocabulary {
            for stem in SpokenForms.stems(in: term) {
                addTerm(stem)
            }
            addTerm(term)
        }
        for term in projectTerms {
            for stem in SpokenForms.stems(in: term) {
                addTerm(stem)
            }
            addTerm(term)
        }

        for term in glossary {
            for heard in SpokenForms.expansions(for: term) {
                claim(heard, written: term)
                if generated.count >= maxGenerated { break }
            }
            if generated.count >= maxGenerated { break }
        }

        let merged = userReplacements + generated
        cacheLock.lock()
        cachedKey = key
        cachedRules = merged
        cacheLock.unlock()
        return merged
    }

    private static func cacheKey(
        vocabulary: [String],
        projectTerms: [String],
        userReplacements: [TextReplacement]
    ) -> String {
        var parts: [String] = []
        parts.append(contentsOf: vocabulary)
        parts.append("\u{1d}")
        parts.append(contentsOf: projectTerms)
        parts.append("\u{1d}")
        for rule in userReplacements {
            parts.append(rule.heard)
            parts.append("\u{1f}")
            parts.append(rule.written)
            parts.append("\u{1e}")
        }
        return parts.joined()
    }
}
