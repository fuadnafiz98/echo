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

    static func elapsed(_ label: String, _ work: () -> Void) -> Duration {
        let took = elapsed(work)
        let line = "HOTPATH \(label)=\(took) (\(milliseconds(took)) ms)\n"
        print(line, terminator: "")
        let url = URL(fileURLWithPath: "/tmp/echo-hotpath-metrics.txt")
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: false, encoding: .utf8)
        }
        return took
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
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

    static func firstIndex(of needle: String, in source: String) -> String.Index? {
        source.range(of: needle)?.lowerBound
    }

    static func appearsInOrder(_ source: String, _ needles: [String]) -> Bool {
        var searchFrom = source.startIndex
        for needle in needles {
            guard let range = source.range(of: needle, range: searchFrom..<source.endIndex) else {
                return false
            }
            searchFrom = range.upperBound
        }
        return true
    }

    static func occurrences(of needle: String, in source: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchFrom = source.startIndex
        while searchFrom < source.endIndex,
              let range = source.range(of: needle, range: searchFrom..<source.endIndex) {
            ranges.append(range)
            searchFrom = range.upperBound
        }
        return ranges
    }

    /// Swift `await`, not English "awaits" in comments.
    static func containsAwaitKeyword(_ source: String) -> Bool {
        source.range(of: #"\bawait\b"#, options: .regularExpression) != nil
    }
}
