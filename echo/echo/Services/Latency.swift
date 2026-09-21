import Foundation
import os

/// Hot-path instrumentation. Signposts for Instruments, plus one `.notice` line per take so
/// latency is visible in the field with
/// `log show --predicate 'subsystem == "echo"' --last 1h`.
///
/// `Logger.debug` is **not** persisted by the unified log, which is why the old
/// `#if DEBUG ... latencyLog.debug` lines never showed up in `log show`.
nonisolated enum Latency: Sendable {
    static let subsystem = "echo"

    static let log = Logger(subsystem: subsystem, category: "latency")
    static let signposter = OSSignposter(subsystem: subsystem, category: "latency")

    /// Milliseconds since `start`, for a `CFAbsoluteTimeGetCurrent()` stamp.
    static func milliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    static func hotkeyToChip(_ ms: Double) {
        log.notice("hotkey→chip \(ms, format: .fixed(precision: 1))ms")
    }

    static func engineRunning(_ ms: Double, restarted: Bool) {
        log.notice(
            "hotkey→engineRunning \(ms, format: .fixed(precision: 1))ms restarted=\(restarted, privacy: .public)"
        )
    }

    static func firstBuffer(_ ms: Double) {
        log.notice("hotkey→firstBuffer \(ms, format: .fixed(precision: 1))ms")
    }

    static func recognition(_ ms: Double, provider: String, seconds: Double, streamed: Bool) {
        log.notice(
            """
            stop→transcript \(ms, format: .fixed(precision: 1))ms \
            provider=\(provider, privacy: .public) \
            audio=\(seconds, format: .fixed(precision: 1))s \
            streamed=\(streamed, privacy: .public)
            """
        )
    }

    static func paste(_ ms: Double, provider: String, words: Int) {
        log.notice(
            """
            stop→paste \(ms, format: .fixed(precision: 1))ms \
            provider=\(provider, privacy: .public) words=\(words)
            """
        )
    }

    static func launch(_ ms: Double) {
        log.notice("launch→hotkeyArmed \(ms, format: .fixed(precision: 1))ms")
    }

    static func note(_ message: String) {
        log.notice("\(message, privacy: .public)")
    }
}
