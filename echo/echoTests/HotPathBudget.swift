import Foundation

/// Intent is ~5 ms for a paragraph. Bounds are 10× so a loaded CI runner does not flake.
enum HotPathBudget {
    static let paragraph = Duration.milliseconds(50)
    static let cleanupFirstCall = Duration.milliseconds(100)
    static let cachedPresenceLookups = Duration.milliseconds(100)
    static let presenceLookupCount = 5_000

    static func elapsed(_ work: () -> Void) -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        work()
        return clock.now - start
    }
}

enum AppSource {
    static func load(_ relativePath: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testsDir
            .deletingLastPathComponent()
            .appendingPathComponent("echo", isDirectory: true)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func method(_ source: String, named name: String) -> String? {
        let needle = "func \(name)("
        guard let start = source.range(of: needle) else { return nil }
        guard let brace = source[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = brace
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[start.lowerBound...index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
