import Foundation

enum FillerStripper {
    private static let fillers = "um+|uhm|uh+|er|erm"

    // Compiled once. These used to be rebuilt on every paste, which is pure overhead on the
    // one path where latency is felt.
    private static let bracketedFiller = try? NSRegularExpression(
        pattern: #",\s*(?:\#(fillers))\s*,"#,
        options: [.caseInsensitive]
    )
    private static let standaloneFiller = try? NSRegularExpression(
        pattern: #"\b(?:\#(fillers))\b[.,]?"#,
        options: [.caseInsensitive]
    )
    private static let runOfSpaces = try? NSRegularExpression(pattern: #"\s{2,}"#)

    static func apply(_ text: String) -> String {
        var result = text
        result = replace(result, using: bracketedFiller, with: " ")
        result = replace(result, using: standaloneFiller, with: "")
        result = replace(result, using: runOfSpaces, with: " ")
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " .", with: ".")
        result = result.replacingOccurrences(of: ",,", with: ",")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(
        _ text: String,
        using regex: NSRegularExpression?,
        with template: String
    ) -> String {
        guard let regex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
