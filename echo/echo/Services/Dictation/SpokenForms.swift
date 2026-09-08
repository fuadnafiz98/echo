import Foundation

enum SpokenForms {
    static let maxFormsPerTerm = 20

    static func expansions(for written: String) -> [String] {
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var seen = Set<String>()
        var forms: [String] = []
        func append(_ phrase: String) {
            let value = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = value.lowercased()
            guard !value.isEmpty, seen.insert(key).inserted else { return }
            guard value.caseInsensitiveCompare(trimmed) != .orderedSame else { return }
            guard !isBlockedHeard(value) else { return }
            forms.append(value)
        }

        let pieces = pieces(in: trimmed)
        let tokens = tokens(from: pieces)
        let allowHomophones = tokens.count >= 3
        if tokens.count >= 2 || tokens.contains(where: { $0.contains(where: \.isNumber) }) {
            let options = tokens.map { variants($0, allowHomophones: allowHomophones) }
            for combo in cartesian(options) {
                append(combo.joined(separator: " "))
                for extra in compact(combo) {
                    append(extra)
                }
                if forms.count >= maxFormsPerTerm { return forms }
            }
        }

        if pieces.count >= 2 {
            append(pieces.joined())
            append(pieces.joined(separator: " "))
            append(pieces.joined(separator: "-"))
        }

        if trimmed.contains("-"), pieces.count >= 2 {
            append(pieces.joined(separator: " dash "))
        }
        if trimmed.contains("."), pieces.count >= 2 {
            append(pieces.joined(separator: " dot "))
            append(pieces.joined(separator: " . "))
            if let spelled = spelledLetters(pieces.last ?? "") {
                let head = pieces.dropLast().joined(separator: " ")
                append("\(head) dot \(spelled)")
                append("\(head) \(spelled)")
                append("\(head).\(spelled)")
            }
        }
        if trimmed.contains("/"), pieces.count >= 2 {
            append(pieces.joined(separator: " slash "))
        }

        for chunk in letterDigitChunks(in: trimmed) {
            for alias in shortDigitAliases(for: chunk) {
                append(alias)
                if forms.count >= maxFormsPerTerm { return forms }
            }
        }

        if pieces.count >= 2, let last = pieces.last, isDistinctiveSegment(last) {
            append(last)
        }

        return Array(forms.prefix(maxFormsPerTerm))
    }

    /// Product stems such as `aim2` from `aim2-core`, used as written targets for short aliases.
    static func stems(in written: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func add(_ term: String) {
            let value = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 2 else { return }
            guard seen.insert(value.lowercased()).inserted else { return }
            guard value.caseInsensitiveCompare(written) != .orderedSame else { return }
            result.append(value)
        }
        for chunk in letterDigitChunks(in: written) {
            add(chunk)
        }
        if written.contains("-") || written.contains("_") {
            let first = written.split { $0 == "-" || $0 == "_" }.first.map(String.init) ?? ""
            if isDistinctiveSegment(first) {
                add(first)
            }
        }
        return result
    }

    static func isBlockedHeard(_ heard: String) -> Bool {
        let key = heard.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if blockedHeard.contains(key) { return true }
        let words = key.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count == 1, blockedHeard.contains(words[0]) { return true }
        if words.count <= 2, let last = words.last, homophones.contains(last) { return true }
        return false
    }

    /// Short Settings caption of how a word is likely to be heard.
    static func settingsCaption(for written: String) -> String? {
        let forms = expansions(for: written)
        guard !forms.isEmpty else { return nil }

        let shorts = forms.filter { form in
            form.split(whereSeparator: \.isWhitespace).count <= 2 || form.count <= 8
        }
        let longs = forms.filter(isPersistableSpokenForm)

        var picked: [String] = []
        var seen = Set<String>()
        func take(_ form: String) {
            let key = form.lowercased()
            guard seen.insert(key).inserted else { return }
            picked.append(form)
        }
        for form in shorts.prefix(2) { take(form) }
        for form in longs.prefix(2) where picked.count < 3 { take(form) }
        if picked.isEmpty {
            for form in forms.prefix(3) { take(form) }
        }
        return picked.isEmpty ? nil : picked.joined(separator: ", ")
    }

    static func isPersistableSpokenForm(_ heard: String) -> Bool {
        let words = heard.split { $0.isWhitespace || $0 == "-" || $0 == "." }.filter { !$0.isEmpty }
        return words.count >= 3
    }

    private static func pieces(in written: String) -> [String] {
        written
            .split { $0 == "-" || $0 == "." || $0 == "_" || $0 == "/" || $0.isWhitespace }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func tokens(from pieces: [String]) -> [String] {
        var tokens: [String] = []
        for piece in pieces {
            tokens.append(contentsOf: splitLettersAndDigits(piece))
        }
        return tokens
    }

    private static func compact(_ combo: [String]) -> [String] {
        guard combo.count >= 2 else { return [] }
        var extras: [String] = []
        for index in combo.indices where Int(combo[index]) != nil {
            if index > 0 {
                var glued = combo
                glued[index - 1] += glued[index]
                glued.remove(at: index)
                extras.append(glued.joined(separator: " "))
                extras.append(glued.joined())
            }
            if index + 1 < combo.count {
                var glued = combo
                glued[index] += glued[index + 1]
                glued.remove(at: index + 1)
                extras.append(glued.joined(separator: " "))
            }
        }
        extras.append(combo.dropLast().joined(separator: " ") + "-" + combo.last!)
        return extras
    }

    private static func splitLettersAndDigits(_ piece: String) -> [String] {
        var current = ""
        var lastWasDigit: Bool?
        var parts: [String] = []
        for character in piece {
            let digit = character.isNumber
            if let lastWasDigit, lastWasDigit != digit {
                parts.append(current)
                current = ""
            }
            current.append(character)
            lastWasDigit = digit
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func letterDigitChunks(in written: String) -> [String] {
        guard let regex = alnumProductRegex else { return [] }
        let range = NSRange(written.startIndex..., in: written)
        return regex.matches(in: written, range: range).compactMap { match in
            Range(match.range, in: written).map { String(written[$0]) }
        }
    }

    private static func shortDigitAliases(for chunk: String) -> [String] {
        let parts = splitLettersAndDigits(chunk)
        guard parts.count >= 2 else { return [] }
        var aliases: [String] = []
        for index in parts.indices where index > 0 && parts[index].allSatisfy(\.isNumber) {
            let letters = parts[index - 1]
            guard let last = letters.last, last.isLetter else { continue }
            let digits = parts[index]
            aliases.append(String(last) + digits)
            aliases.append(String(last) + " " + digits)
            if let number = Int(digits), let words = numberWords[number] {
                for word in words where !homophones.contains(word) {
                    aliases.append(String(last) + " " + word)
                }
            }
        }
        return aliases
    }

    private static func variants(_ token: String, allowHomophones: Bool) -> [String] {
        if let number = Int(token), let words = numberWords[number] {
            if allowHomophones {
                return [token] + words
            }
            return [token] + words.filter { !homophones.contains($0) }
        }
        return [token]
    }

    private static func spelledLetters(_ token: String) -> String? {
        guard token.count >= 2, token.count <= 3, token.allSatisfy(\.isLetter) else { return nil }
        return token.map { String($0).lowercased() }.joined(separator: " ")
    }

    static func isDistinctiveSegment(_ segment: String) -> Bool {
        let value = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2, !blockedHeard.contains(value.lowercased()) else { return false }
        if value.contains(where: \.isNumber) || value.contains(".") || value.contains("_") {
            return true
        }
        let letters = value.filter(\.isLetter)
        return letters.count >= 2 && letters.contains(where: \.isUppercase) && letters.contains(where: \.isLowercase)
    }

    private static func cartesian(_ lists: [[String]]) -> [[String]] {
        lists.reduce([[]]) { partial, next in
            partial.flatMap { prefix in next.map { prefix + [$0] } }
        }
    }

    private static let alnumProductRegex = try? NSRegularExpression(pattern: #"[A-Za-z]{2,}[0-9][A-Za-z0-9]*"#)

    private static let homophones: Set<String> = ["to", "too", "for"]

    private static let numberWords: [Int: [String]] = [
        0: ["zero"],
        1: ["one"],
        2: ["two", "to"],
        3: ["three"],
        4: ["four", "for"],
        5: ["five"],
        6: ["six"],
        7: ["seven"],
        8: ["eight"],
        9: ["nine"],
        10: ["ten"],
    ]

    private static let blockedHeard: Set<String> = [
        "a", "an", "the", "and", "or", "but", "to", "too", "of", "in", "on", "for",
        "with", "as", "at", "by", "from", "is", "it", "be", "if", "so", "do",
        "we", "you", "my", "me", "our", "this", "that", "plot", "core", "app",
        "api", "new", "use", "set", "get", "put", "end", "all", "any", "not",
        "can", "will", "just", "like", "also", "into", "over", "out", "up",
        "down", "one", "two", "four", "file", "name", "type", "data", "test",
        "main", "index", "src", "lib", "bin", "pkg", "mod",
    ]
}
