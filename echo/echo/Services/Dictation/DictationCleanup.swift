import Foundation

/// Sync paste-path cleanup. Never awaits S1 / Apple Intelligence polish.
enum DictationCleanup {
    /// Local cleanup never drops the take. Filler strip is rejected if it shrinks meaning.
    static func apply(
        _ raw: String,
        stripFillers: Bool,
        vocabulary: [String] = [],
        projectTerms: [String] = [],
        userReplacements: [TextReplacement] = []
    ) -> String {
        var text = raw

        if stripFillers {
            let stripped = FillerStripper.apply(text)
            if keepsMeaning(stripped, of: raw) {
                text = stripped
            }
        }

        let rules = SpokenAliasTable.replacements(
            vocabulary: vocabulary,
            projectTerms: projectTerms,
            userReplacements: userReplacements
        )
        let replaced = ReplacementEngine.apply(text, replacements: rules)
        if !replaced.isEmpty {
            text = replaced
        }

        // User replacements win. Path / @ / handle glue is local and never awaits polish.
        text = SpokenPathNormalizer.apply(text)

        return text.isEmpty ? raw : text
    }

    /// Filler-aware retention against the post-local baseline, not raw STT.
    static func keepsMeaning(_ candidate: String, of original: String) -> Bool {
        let polished = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !polished.isEmpty else { return false }
        let polishedWords = polished.split(whereSeparator: \.isWhitespace)
        let sourceWords = source.split(whereSeparator: \.isWhitespace)
        guard !sourceWords.isEmpty else { return true }
        if sourceWords.count <= 8 {
            return polishedWords.count >= max(1, sourceWords.count - 2)
        }

        let sourceContent = contentTokens(in: source)
        let polishedContent = Set(contentTokens(in: polished))
        guard !sourceContent.isEmpty else {
            return polishedWords.count >= sourceWords.count / 2
        }
        let retained = sourceContent.filter { polishedContent.contains($0) }.count
        let retention = Double(retained) / Double(sourceContent.count)
        let wordRatio = Double(polishedWords.count) / Double(sourceWords.count)
        if retention >= 0.88, wordRatio >= 0.70 { return true }
        if polishedWords.count >= sourceWords.count || polished.count >= source.count {
            return retention >= 0.75
        }
        return false
    }

    private static func contentTokens(in text: String) -> [String] {
        let stop: Set<String> = [
            "a", "an", "the", "and", "or", "but", "to", "of", "in", "on", "for", "with",
            "um", "uh", "er", "erm", "uhm", "like", "you", "know",
        ]
        return text
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map { $0.lowercased() }
            .filter { $0.count > 1 && !stop.contains($0) }
    }
}
