import Foundation

enum FillerStripper {
    private static let fillers = "um+|uhm|uh+|er|erm"

    static func apply(_ text: String) -> String {
        var result = text
        result = replace(result, pattern: #",\s*(?:\#(fillers))\s*,"#, with: " ")
        result = replace(result, pattern: #"\b(?:\#(fillers))\b[.,]?"#, with: "")
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " .", with: ".")
        result = result.replacingOccurrences(of: ",,", with: ",")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
