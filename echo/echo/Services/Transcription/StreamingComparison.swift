import AVFoundation
import Foundation

/// Opt-in accuracy check for the streaming pipeline on real voices.
///
/// Synthetic benchmark speech is clean and unaccented, so it cannot show where pause windows lose
/// words that one whole-take decode keeps. With `defaults write
/// ~/Library/Preferences/com.fuadnafiz98.echo.plist debugCompareStreaming -bool YES` (the path,
/// not the bundle id: an old sandbox container makes `defaults` write the flag where this
/// unsandboxed app never reads it), every streaming take keeps its audio and, after the paste, is
/// decoded again the standard way. Both transcripts land in `compare.jsonl` next to the WAVs, and the benchmark can
/// replay the WAVs (`ECHO_BENCH_TAKES`) to tune the layout against them.
///
/// Off by default. Stays on this Mac; nothing is uploaded. Compiled only into builds made with
/// `ECHO_STREAM_COMPARE=1 scripts/install-release.sh`; a normal build carries none of it.
#if ECHO_STREAM_COMPARE
nonisolated enum StreamingComparison {
    static let defaultsKey = "debugCompareStreaming"

    /// Never under XCTest: the test host shares the app's defaults, and a benchmark replaying the
    /// saved takes would otherwise save every replay as a new take.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static var directory: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("echo", isDirectory: true)
            .appendingPathComponent("stream-compare", isDirectory: true)
    }

    /// Called at stop with the streamed text. The re-decode waits until the paste is done.
    static func record(
        samples: [Float],
        streamed: String,
        stats: PauseWindowPipeline.Stats?,
        decode: @escaping @Sendable ([Float]) async throws -> String
    ) {
        guard !samples.isEmpty else {
            Latency.note("stream compare skipped: no samples")
            return
        }
        Latency.note("stream compare queued \(samples.count) samples")
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1))
            let batch = (try? await decode(samples)) ?? ""
            let stamp = ISO8601DateFormatter.string(
                from: .now, timeZone: .current, formatOptions: [.withFullDate, .withTime, .withTimeZone]
            ).replacingOccurrences(of: ":", with: "")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let wav = directory.appendingPathComponent("take-\(stamp).wav")
                try write(samples, to: wav)
                var line: [String: Any] = [
                    "file": wav.lastPathComponent,
                    "seconds": Double(samples.count) / AudioResampler.targetSampleRate,
                    "streamed": streamed,
                    "batch": batch,
                    "same": normalized(streamed) == normalized(batch),
                ]
                if let stats {
                    line["cuts"] = stats.cuts
                    line["forcedCuts"] = stats.forcedCuts
                    line["tailSeconds"] = stats.tailSeconds
                    line["speculativeHit"] = stats.speculativeHit
                    line["reused"] = stats.reusedSpeculation
                    line["anticipated"] = stats.anticipated
                    line["stopPath"] = stats.stopPath
                }
                try append(line, to: directory.appendingPathComponent("compare.jsonl"))
                Latency.note("stream compare \(wav.lastPathComponent) same=\(line["same"] as? Bool ?? false)")
            } catch {
                Latency.note("stream compare failed: \(error.localizedDescription)")
            }
        }
    }

    private static func normalized(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.filter { $0.isLetter || $0.isNumber || $0 == "'" } }
            .filter { !$0.isEmpty }
    }

    private static func write(_ samples: [Float], to url: URL) throws {
        guard let buffer = AudioResampler.pcmBuffer(from: samples) else { return }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioResampler.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private static func append(_ object: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }
}
#endif
