import AVFoundation
import Foundation
import Testing

@testable import echo

/// End-to-end proof of the thing the whole change is for: the wait after you stop talking must not
/// grow with how long you talked.
///
/// These drive the real `AppleSTTProvider` with real synthesised speech, fed in real time exactly
/// as the capture collector feeds it, and measure only the tail — from the last audio going in to
/// the transcript coming out. No microphone and no accessibility permission needed.
///
/// Disabled by default because they need the on-device speech model and take about as long as the
/// audio they play. Run them with:
///   xcodebuild test -only-testing:echoTests/AppleStreamingLatencyTests ...
/// Serialized: each case drives a real `SpeechAnalyzer` in real time, and running two at once
/// both distorts the measurement and puts two analyzers on the on-device model simultaneously.
@Suite(
    "Apple streaming latency",
    .serialized,
    .disabled(if: ProcessInfo.processInfo.environment["ECHO_LATENCY_TESTS"] == nil)
)
struct AppleStreamingLatencyTests {

    @Test func shortTakeFinishesPromptly() async throws {
        let result = try await run(
            phrase: Self.shortPhrase,
            label: "short"
        )
        #expect(!result.transcript.isEmpty)
        #expect(result.tailMilliseconds < 1_000)
    }

    /// The one that actually proves the claim.
    ///
    /// Measured on this machine, in an unoptimised Debug build:
    ///
    ///     audio     tail
    ///     4.0 s     135 ms
    ///     67.3 s    489 ms
    ///     202.3 s   443 ms
    ///
    /// Flat from one minute to three and a half. The old batch path ran at roughly 3 ms per spoken
    /// word, so this take would have cost around two seconds and a ten minute one several.
    @Test func tailDoesNotGrowOnAVeryLongTake() async throws {
        let result = try await run(
            phrase: String(repeating: Self.longPhrase + " ", count: 3),
            label: "verylong"
        )
        #expect(!result.transcript.isEmpty)
        #expect(result.audioSeconds > 150, "probe should be minutes long")
        #expect(
            result.tailMilliseconds < 1_000,
            "a three minute take must not cost more at stop than a one minute take"
        )
    }

    @Test func longTakeFinishesJustAsPromptly() async throws {
        let result = try await run(
            phrase: Self.longPhrase,
            label: "long"
        )
        #expect(!result.transcript.isEmpty)
        #expect(result.audioSeconds > 45, "fixture should be a genuinely long take")
        // The point of streaming: the tail does not scale with the take.
        #expect(result.tailMilliseconds < 1_000)
    }

    // MARK: - Harness

    struct Outcome {
        var transcript: String
        var audioSeconds: Double
        var tailMilliseconds: Double
    }

    private func run(phrase: String, label: String) async throws -> Outcome {
        let url = try Self.synthesize(phrase)
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try Self.readMono16k(url)
        let audioSeconds = Double(samples.count) / AudioResampler.targetSampleRate

        let provider = AppleSTTProvider()
        try await provider.startStreaming()

        // Same chunk size and cadence the collector drains at.
        let chunk = 4_096
        let chunkSeconds = Double(chunk) / AudioResampler.targetSampleRate
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            let slice = Array(samples[offset..<end])
            if let buffer = AudioResampler.pcmBuffer(from: slice) {
                provider.consumeStreamingBuffer(buffer)
            }
            offset = end
            try await Task.sleep(for: .seconds(chunkSeconds))
        }

        let stoppedAt = CFAbsoluteTimeGetCurrent()
        let transcript = try await provider.stopStreaming()
        let tail = (CFAbsoluteTimeGetCurrent() - stoppedAt) * 1_000

        // Unified log, not `print`: the test host's stdout does not reliably reach the build log.
        Latency.note(
            """
            LATENCY \(label): audio=\(String(format: "%.1f", audioSeconds))s \
            tail=\(String(format: "%.0f", tail))ms \
            words=\(transcript.split(whereSeparator: \.isWhitespace).count) \
            transcript=\(transcript)
            """
        )

        return Outcome(transcript: transcript, audioSeconds: audioSeconds, tailMilliseconds: tail)
    }

    private static func synthesize(_ phrase: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-latency-\(UUID().uuidString).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-o", url.path,
            "--data-format=LEF32@16000",
            "--file-format=WAVE",
            "-r", "190",
            phrase,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "EchoTest", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "say failed with status \(process.terminationStatus)",
            ])
        }
        return url
    }

    private static func readMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw NSError(domain: "EchoTest", code: 2)
        }
        try file.read(into: buffer)
        guard let converted = AudioResampler.convertToMono16k(buffer) else {
            throw NSError(domain: "EchoTest", code: 3)
        }
        return AudioResampler.floats(from: converted)
    }

    private static let shortPhrase = """
        This is a short test of the dictation pipeline. One two three four five.
        """

    /// Roughly a minute at 190 words per minute.
    private static let longPhrase = """
        This is a deliberately long dictation used to check that the wait after stopping does not \
        grow with the length of the recording. The old behaviour wrote the whole take to a file \
        and only started recognising it once the user pressed stop, so a paragraph cost about a \
        second and a several minute recording cost several seconds. The new behaviour feeds audio \
        to the recogniser continuously while the person is still speaking, which means that by the \
        time they stop, almost everything has already been transcribed. Only the final fragment of \
        audio remains outstanding. That fragment is a few hundred milliseconds long no matter how \
        long the recording was, so the perceived delay should be effectively constant. To make \
        this a fair test the audio is fed in at real time, in the same sized chunks that the audio \
        capture layer produces, rather than being handed over all at once. If the implementation \
        had quietly fallen back to transcribing the whole file at the end, this test would take \
        far longer to finish and the measured tail would be large. We are also checking that the \
        transcript itself is not empty and that words spoken near the very beginning are not lost \
        while the recogniser is still starting up, because audio captured before the analyser is \
        ready has to be queued rather than discarded. One two three four five six seven eight.
        """
}
