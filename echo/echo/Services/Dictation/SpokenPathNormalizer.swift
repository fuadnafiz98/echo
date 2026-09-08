import Foundation

/// Fast local glue for spoken paths, @, and handles. Runs after user replacements.
///
/// Structural rules only — no path, handle, or filename literals:
/// - Collapse spaces around `/` and `//+` → `/` when the span is a path
///   (starts with `/`, or has 2+ slash-separated identifier-like segments).
/// - Spoken `slash` between identifier-like tokens → `/` (never “use a slash to”).
/// - `at the rate` / `add the rate` / `at rate` / `at sign` → `@`, then glue `@`
///   to the next identifier-like token (not English stopwords).
/// - Join `a _ b _ c` / `a underscore b` into `a_b_c` when pieces are short identifiers.
/// - `at list` / `at least` → `test` only as the last segment of an `@handle` or
///   underscore-identifier. Prose “at least” is left alone.
/// - Filename `word.ext` and `word dot …` rewrite extensions only via a phonetic
///   extension table, applied to any basename.
nonisolated enum SpokenPathNormalizer: Sendable {
    static func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        result = rewriteAtPhrases(result)
        result = rewriteHandleFinalTest(result)
        result = glueUnderscoreChains(result)
        result = glueAtHandles(result)
        result = glueSpokenSlashPaths(result)
        result = gluePathLikeSpans(result)
        result = fixFilenameExtensions(result)
        result = collapseExtraSpaces(result)
        return result
    }

    /// Generic cases first. The original dictation sentence is last and must pass
    /// only because of those rules — nothing in the rewriter names its words.
    static func fixtureCases() -> [(name: String, input: String, expected: String)] {
        let said = """
        / computers / developers / downloads agents.nt check the python.py and also the tests folder and also you will find that in the components// icons folder, you will find all the icons, and also in the test.py, and also feature.py, you'll find that there are some features that we are already having. Also, in the at the rate also and after you are done mail everything to add the rate s _ a _ at list.
        """
        let wanted = """
        /computers/developers/downloads agents.md check the python.py and also the tests folder and also you will find that in the components/icons folder, you will find all the icons, and also in the test.py, and also feature.py, you'll find that there are some features that we are already having. Also, in the @ also and after you are done mail everything to @s_a_test.
        """
        return [
            (name: "spaced absolute path", input: "/ foo / bar / baz", expected: "/foo/bar/baz"),
            (name: "double slash folder", input: "pkg// utils", expected: "pkg/utils"),
            (name: "two identifier slashes", input: "src / lib", expected: "src/lib"),
            (name: "filename nt any basename", input: "notes.nt", expected: "notes.md"),
            (name: "filename emt any basename", input: "readme.emt", expected: "readme.md"),
            (name: "dot n t any basename", input: "notes dot n t", expected: "notes.md"),
            (name: "dot jay ess any basename", input: "script dot jay ess", expected: "script.js"),
            (name: "handle at list", input: "add the rate foo _ bar _ at list", expected: "@foo_bar_test"),
            (name: "handle at least", input: "@ zed_qux_ at least", expected: "@zed_qux_test"),
            (name: "at sign handle", input: "at sign zed _ qux", expected: "@zed_qux"),
            (name: "short letter pieces", input: "x _ y _ z", expected: "x_y_z"),
            (name: "at the rate also", input: "in the at the rate also", expected: "in the @ also"),
            (name: "keep py", input: "python.py test.py feature.py tests folder", expected: "python.py test.py feature.py tests folder"),
            (name: "prose at least", input: "I will at least try the tests folder.", expected: "I will at least try the tests folder."),
            (name: "standalone nt", input: "the nt driver and also nt.", expected: "the nt driver and also nt."),
            (name: "prose slash", input: "use a slash to separate ideas", expected: "use a slash to separate ideas"),
            (name: "prose slash after default rule", input: "use a / to separate ideas", expected: "use a / to separate ideas"),
            (name: "url slashes", input: "see https://example.com/foo", expected: "see https://example.com/foo"),
            (name: "spoken slash path chain", input: "src slash lib slash bin", expected: "src/lib/bin"),
            (name: "spoken slash two tokens", input: "foo slash bar", expected: "foo/bar"),
            (name: "user sentence via generic rules", input: said, expected: wanted),
        ]
    }

    static func failedFixtureCases() -> [(name: String, expected: String, got: String)] {
        fixtureCases().compactMap { fixture in
            let got = apply(fixture.input)
            guard got != fixture.expected else { return nil }
            return (fixture.name, fixture.expected, got)
        }
    }

    static func assertFixtureCases() {
        let failures = failedFixtureCases()
        precondition(
            failures.isEmpty,
            failures.map { "\($0.name): expected \($0.expected) got \($0.got)" }.joined(separator: "\n")
        )
    }

    // MARK: - @ phrases

    private static func rewriteAtPhrases(_ text: String) -> String {
        replace(text, pattern: #"\b(?:at the rate|add the rate|at rate|at sign)\b"#, with: "@")
    }

    /// Spoken confusion for `test` only as the last segment of an `@handle`
    /// or underscore-identifier (`@foo_bar_ at list` → `@foo_bar_test`).
    /// Not a global “at least” → “test” map.
    private static func rewriteHandleFinalTest(_ text: String) -> String {
        var result = replace(text, pattern: #"(?<=@)\s*(?:at list|at least)\b"#, with: "test")
        result = replace(
            result,
            pattern: #"(?<=[A-Za-z0-9])\s*(?:_|underscore)\s*(?:at list|at least)\b"#,
            with: "_test"
        )
        return result
    }

    private static func glueUnderscoreChains(_ text: String) -> String {
        let pattern = #"(?<![[:alnum:]])[A-Za-z0-9]+(?:\s*(?:_|underscore)\s*[A-Za-z0-9]+)+(?:\s*(?:_|underscore))?"#
        return replaceMatches(in: text, pattern: pattern) { snippet in
            let normalized = snippet.replacingOccurrences(
                of: "underscore",
                with: "_",
                options: .caseInsensitive
            )
            let endsWithSep = normalized.trimmingCharacters(in: .whitespaces).hasSuffix("_")
            let tokens = normalized
                .split(separator: "_", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard tokens.count >= 2 else { return snippet }
            guard tokens.allSatisfy(isShortIdentifierPiece) else { return snippet }
            var joined = tokens.joined(separator: "_")
            if endsWithSep {
                joined += "_"
            }
            return joined
        }
    }

    private static let proseAfterAt: Set<String> = [
        "a", "an", "the", "and", "or", "but", "also", "after", "before", "when",
        "then", "if", "so", "as", "at", "by", "to", "of", "in", "on", "for",
        "with", "from", "into", "over", "out", "up", "down", "is", "it", "this",
        "that", "these", "those", "you", "we", "they", "i", "me", "my", "our",
        "your", "not", "just", "like", "all", "any", "can", "will", "there",
        "here", "than", "too", "very", "more", "some", "such", "once",
    ]

    private static func glueAtHandles(_ text: String) -> String {
        replaceMatches(in: text, pattern: #"@\s+([A-Za-z][A-Za-z0-9._-]*)"#) { snippet in
            let rest = snippet.drop(while: { $0 == "@" || $0.isWhitespace })
            let word = String(rest)
            if proseAfterAt.contains(word.lowercased()) {
                return snippet
            }
            return "@" + word
        }
    }

    // MARK: - Paths

    /// Spoken "slash" only between identifier-like tokens, never bare prose.
    private static func glueSpokenSlashPaths(_ text: String) -> String {
        var current = text
        current = replaceMatches(
            in: current,
            pattern: #"(?<![[:alnum:]])[A-Za-z][A-Za-z0-9._-]{1,}(?:\s+slash\s+[A-Za-z][A-Za-z0-9._-]{1,})+"#
        ) { snippet in
            let parts = snippet
                .replacingOccurrences(of: "slash", with: "/", options: .caseInsensitive)
                .split(separator: "/")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard parts.count >= 2, parts.allSatisfy(isPathIdentifier) else { return snippet }
            return parts.joined(separator: "/")
        }
        current = replace(
            current,
            pattern: #"(?<![[:alnum:]])slash\s+(?=[A-Za-z0-9._-]+/)"#,
            with: "/"
        )
        return current
    }

    private static func gluePathLikeSpans(_ text: String) -> String {
        let pattern = #"(?:[A-Za-z0-9._-]+\s*)?(?:/+\s*)+[A-Za-z0-9._-]+(?:\s*/+\s*[A-Za-z0-9._-]+)*"#
        return replaceMatches(in: text, pattern: pattern) { snippet, full, range in
            if range.location > 0 {
                let prev = (full as NSString).character(at: range.location - 1)
                if prev == UInt16(UnicodeScalar(":").value), snippet.hasPrefix("//") {
                    return snippet
                }
            }
            guard isPathLikeSpan(snippet) else { return snippet }
            var compact = replace(snippet, pattern: #"\s*/+\s*"#, with: "/")
            compact = replace(compact, pattern: #"(?<!:)/{2,}"#, with: "/")
            return compact
        }
    }

    private static let pathStopwords: Set<String> = [
        "a", "an", "the", "and", "or", "to", "of", "in", "on", "for", "with",
        "as", "at", "by", "from", "is", "it", "be", "use",
    ]

    private static func isPathLikeSpan(_ snippet: String) -> Bool {
        let segments = snippet
            .split { $0 == "/" || $0.isWhitespace }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let identifiers = segments.filter(isPathIdentifier)
        let trimmed = snippet.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") {
            return !identifiers.isEmpty
        }
        return identifiers.count >= 2
    }

    private static func isPathIdentifier(_ segment: String) -> Bool {
        guard segment.count >= 2 else { return false }
        guard !pathStopwords.contains(segment.lowercased()) else { return false }
        return segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
    }

    private static func isShortIdentifierPiece(_ token: String) -> Bool {
        let value = token.trimmingCharacters(in: .whitespaces)
        guard (1...12).contains(value.count) else { return false }
        guard value.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        // Single-letter pieces like `a` / `s` / `x` are identifier fragments. Only reject longer stopwords.
        if value.count <= 2 { return true }
        return !proseAfterAt.contains(value.lowercased())
    }

    // MARK: - Extensions

    /// Phonetic / spoken confusions for extensions. Keys are heard forms;
    /// values are the written extension. Applied to any basename.
    private static let extensionAliases: [(heard: String, written: String)] = [
        (heard: "jay ess", written: "js"),
        (heard: "tee ess", written: "ts"),
        (heard: "em t", written: "md"),
        (heard: "n t", written: "md"),
        (heard: "m d", written: "md"),
        (heard: "j s", written: "js"),
        (heard: "t s", written: "ts"),
        (heard: "p y", written: "py"),
        (heard: "emt", written: "md"),
        (heard: "nt", written: "md"),
        (heard: "md", written: "md"),
        (heard: "js", written: "js"),
        (heard: "ts", written: "ts"),
        (heard: "py", written: "py"),
    ]

    private static func fixFilenameExtensions(_ text: String) -> String {
        var result = text
        let aliases = extensionAliases.sorted { $0.heard.count > $1.heard.count }
        for alias in aliases where !alias.heard.contains(where: \.isWhitespace) {
            let heard = NSRegularExpression.escapedPattern(for: alias.heard)
            result = replace(
                result,
                pattern: #"(?<![[:alnum:]])([A-Za-z][A-Za-z0-9_-]*)\."# + heard + #"(?![[:alnum:]])"#,
                with: "$1." + alias.written
            )
        }
        for alias in aliases {
            let heard = alias.heard
                .split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: #"\s+"#)
            result = replace(
                result,
                pattern: #"(?<![[:alnum:]])([A-Za-z][A-Za-z0-9_-]*)\s+dot\s+"# + heard + #"(?![[:alnum:]])"#,
                with: "$1." + alias.written
            )
        }
        return result
    }

    private static func collapseExtraSpaces(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " .", with: ".")
        return result
    }

    // MARK: - Regex

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func replaceMatches(
        in text: String,
        pattern: String,
        transform: (String) -> String
    ) -> String {
        replaceMatches(in: text, pattern: pattern) { snippet, _, _ in
            transform(snippet)
        }
    }

    private static func replaceMatches(
        in text: String,
        pattern: String,
        transform: (String, String, NSRange) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            let snippet = ns.substring(with: match.range)
            let replacement = transform(snippet, text, match.range)
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        return mutable as String
    }
}
