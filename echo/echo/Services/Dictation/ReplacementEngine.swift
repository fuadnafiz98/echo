import Foundation

enum ReplacementEngine {
    private static let cacheLock = NSLock()
    private static var cachedKey = ""
    private static var cachedRegexes: [(NSRegularExpression, String, Int)] = []

    /// Single-pass, longest-heard-first, non-overlapping. User `aim2`→`aim2-core` does not eat a prior `m2`→`aim2`.
    static func apply(_ text: String, replacements: [TextReplacement]) -> String {
        let compiled = compiledRegexes(replacements)
        guard !compiled.isEmpty, !text.isEmpty else { return text }

        struct Hit {
            var start: Int
            var end: Int
            var written: String
            var heardLength: Int
        }

        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var hits: [Hit] = []
        for (regex, written, heardLength) in compiled {
            for match in regex.matches(in: text, options: [], range: full) {
                let range = match.range
                guard range.location != NSNotFound, range.length > 0 else { continue }
                hits.append(
                    Hit(
                        start: range.location,
                        end: range.location + range.length,
                        written: written,
                        heardLength: heardLength
                    )
                )
            }
        }
        guard !hits.isEmpty else { return text }

        hits.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.heardLength != $1.heardLength { return $0.heardLength > $1.heardLength }
            return ($0.end - $0.start) > ($1.end - $1.start)
        }

        var chosen: [Hit] = []
        var cursor = 0
        for hit in hits {
            if hit.start >= cursor {
                chosen.append(hit)
                cursor = hit.end
            }
        }

        var result = ""
        result.reserveCapacity(text.count)
        var last = 0
        for hit in chosen {
            if hit.start > last {
                result += ns.substring(with: NSRange(location: last, length: hit.start - last))
            }
            result += hit.written
            last = hit.end
        }
        if last < ns.length {
            result += ns.substring(from: last)
        }
        return result
    }

    private static func compiledRegexes(
        _ replacements: [TextReplacement]
    ) -> [(NSRegularExpression, String, Int)] {
        let key = replacements.map { $0.heard + "\u{1f}" + $0.written }.joined(separator: "\u{1e}")
        cacheLock.lock()
        if key == cachedKey, !cachedRegexes.isEmpty || replacements.isEmpty {
            let hit = cachedRegexes
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let rules = replacements
            .filter { !$0.heard.isEmpty && !$0.written.isEmpty }
            .sorted { $0.heard.count > $1.heard.count }
        var compiled: [(NSRegularExpression, String, Int)] = []
        compiled.reserveCapacity(rules.count)
        for rule in rules {
            let escaped = NSRegularExpression.escapedPattern(for: rule.heard)
                .replacingOccurrences(of: " ", with: #"\s+"#)
            let pattern = #"(?<![[:alnum:]])"# + escaped + #"(?![[:alnum:]])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            compiled.append((regex, rule.written, rule.heard.count))
        }

        cacheLock.lock()
        cachedKey = key
        cachedRegexes = compiled
        cacheLock.unlock()
        return compiled
    }
}
