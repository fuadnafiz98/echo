import Foundation
import Synchronization
import Testing

@testable import echo

/// The streaming pipeline against a fake recogniser that can be checked exactly.
///
/// Each "word" is a square-wave burst whose amplitude encodes its index, so the fake decoder can
/// name every word in any window it is handed, wherever the window was cut. That makes seams,
/// forced cuts, speculation and the final tail verifiable word for word without the model.
@Suite("Pause window pipeline")
struct PauseWindowPipelineTests {
    static let rate = Int(AudioResampler.targetSampleRate)

    // MARK: - Audio builder

    struct Script {
        var samples: [Float] = []
        var words: [String] = []

        mutating func word(_ index: Int, seconds: Double = 0.3) {
            append(amplitude: FakeRecognizer.amplitude(for: index), seconds: seconds)
            words.append("w\(index)")
        }

        mutating func quietWord(seconds: Double = 0.3) {
            append(amplitude: FakeRecognizer.quietAmplitude, seconds: seconds)
            words.append("quiet")
        }

        mutating func silence(_ seconds: Double) {
            samples.append(contentsOf: [Float](repeating: 0, count: Int(seconds * Double(rate))))
        }

        mutating func click() {
            append(amplitude: 0.3, seconds: 0.012)
        }

        private mutating func append(amplitude: Float, seconds: Double) {
            let count = Int(seconds * Double(rate))
            for i in 0..<count {
                samples.append((i / 8).isMultiple(of: 2) ? amplitude : -amplitude)
            }
        }
    }

    /// Words of 0.3 s with `gap` between them and a longer pause every `sentence` words.
    static func dictation(words: Int, gap: Double = 0.15, sentence: Int = 8, pause: Double = 0.5) -> Script {
        var script = Script()
        for index in 0..<words {
            script.word(index)
            script.silence(index % sentence == sentence - 1 ? pause : gap)
        }
        return script
    }

    // MARK: - Harness

    struct Outcome {
        var text: String
        var stats: PauseWindowPipeline.Stats?
        var decodesAtStop: Int
        var totalDecodes: Int
    }

    static func run(
        _ samples: [Float],
        recognizer: FakeRecognizer = FakeRecognizer(),
        settle: Bool = true
    ) async throws -> Outcome {
        let pipeline = PauseWindowPipeline(decode: recognizer.decode)
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 4_096, samples.count)
            pipeline.append(Array(samples[offset..<end]))
            offset = end
            // Give the worker a chance, as real time would.
            await Task.yield()
        }
        if settle {
            // Let any speculative decode land, as the user's reach for the hotkey would.
            try await Task.sleep(for: .milliseconds(50))
        }
        let before = recognizer.calls
        let text = try await pipeline.finish()
        return Outcome(
            text: text,
            stats: pipeline.stats,
            decodesAtStop: recognizer.calls - before,
            totalDecodes: recognizer.calls
        )
    }

    // MARK: - Tests

    @Test func layoutFitsTheEncoder() {
        #expect(PauseWindowPipeline.Layout.standard.fitsEncoder)
    }

    @Test func everyWordOnceAcrossManyWindows() async throws {
        var script = Self.dictation(words: 120)
        script.silence(0.8)
        let outcome = try await Self.run(script.samples)
        #expect(outcome.text == script.words.joined(separator: " "))
        #expect((outcome.stats?.cuts ?? 0) >= 4, "a ~55 s take must be cut several times")
        #expect(outcome.stats?.forcedCuts == 0, "there are pauses to cut in")
    }

    @Test func stopAfterAPauseRunsNoModel() async throws {
        var script = Self.dictation(words: 30)
        script.silence(0.8)
        let outcome = try await Self.run(script.samples)
        #expect(outcome.text == script.words.joined(separator: " "))
        #expect(outcome.stats?.speculativeHit == true)
        #expect(outcome.decodesAtStop == 0, "the speculative pass should have covered the tail")
    }

    @Test func stopMidWordDecodesTheTail() async throws {
        var script = Self.dictation(words: 30)
        script.word(99, seconds: 0.15) // cut off mid-word, no pause after
        let outcome = try await Self.run(script.samples, settle: false)
        #expect(outcome.text == script.words.joined(separator: " "))
        #expect(outcome.stats?.speculativeHit == false)
        #expect((outcome.stats?.tailSeconds ?? 0) > 0)
    }

    @Test func continuousSpeechIsForceCutWithoutLosingWords() async throws {
        // 100 ms gaps: never a 240 ms pause, so every cut is forced.
        var script = Self.dictation(words: 60, gap: 0.1, sentence: 1_000)
        script.silence(0.8)
        let outcome = try await Self.run(script.samples)
        #expect(outcome.text == script.words.joined(separator: " "))
        #expect((outcome.stats?.forcedCuts ?? 0) >= 1)
    }

    @Test func quietTrailingWordIsNotDropped() async throws {
        var script = Self.dictation(words: 24)
        script.silence(1.2)
        script.quietWord()
        script.silence(0.8)
        let outcome = try await Self.run(script.samples)
        #expect(outcome.text.hasSuffix("quiet"), "got: \(outcome.text)")
    }

    @Test func hotkeyClickDoesNotSpoilTheSpeculativeTail() async throws {
        var script = Self.dictation(words: 20)
        script.silence(0.7)
        script.click()
        script.silence(0.05)
        let outcome = try await Self.run(script.samples)
        #expect(outcome.text == script.words.joined(separator: " "))
        #expect(outcome.stats?.speculativeHit == true)
    }

    /// The stop key's click, as a built-in mic hears it: ~100 ms, loud, right at the end. A real
    /// take (2026-09-23) lost its finished pass to one and paid a 140 ms decode.
    @Test func stopKeyClickAtTheEndDoesNotForceADecode() async throws {
        var script = Self.dictation(words: 20)
        script.silence(0.8)
        let clickLength = Int(0.1 * Double(Self.rate))
        for i in 0..<clickLength {
            script.samples.append((i / 8).isMultiple(of: 2) ? 0.05 : -0.05)
        }
        let outcome = try await Self.run(script.samples)
        #expect(outcome.text == script.words.joined(separator: " "))
        #expect(outcome.decodesAtStop == 0, "path: \(outcome.stats?.stopPath ?? "?")")
    }

    /// The click rule must never eat a word: a short word after a pause, right at stop, is
    /// longer than a click and has to be decoded.
    @Test func shortLastWordRightAtStopIsStillDecoded() async throws {
        var script = Self.dictation(words: 20)
        script.silence(0.8)
        script.word(20, seconds: 0.2)
        let outcome = try await Self.run(script.samples)
        #expect(outcome.text == script.words.joined(separator: " "), "got: \(outcome.text)")
    }

    /// A quiet built-in mic from real takes: floor 0.0023, speech p90 0.0085. The old 12% rule
    /// put the speech threshold at 0.003, inside the noise's flicker.
    @Test func quietMicSpeechThresholdClearsTheFloorBySixDecibels() {
        var energies = [Float](repeating: 0.0023, count: 120)
        energies += [Float](repeating: 0.004, count: 60)
        energies += [Float](repeating: 0.0085, count: 120)
        let (floor, threshold) = PauseWindowPipeline.threshold(for: energies)
        #expect(floor == 0.0023)
        #expect(threshold < 2 * floor, "cut points keep the old rule")
        let speech = PauseWindowPipeline.speechThreshold(floor: floor, threshold: threshold, frames: energies.count)
        #expect(speech >= 2 * floor)
        // Loud speech keeps the proportional rule.
        let loud = [Float](repeating: 0.0023, count: 150) + [Float](repeating: 0.1, count: 150)
        let l = PauseWindowPipeline.threshold(for: loud)
        #expect(PauseWindowPipeline.speechThreshold(floor: l.floor, threshold: l.threshold, frames: 300) == l.threshold)
        // Under 150 frames the floor may be speech; no extra margin there.
        #expect(PauseWindowPipeline.speechThreshold(floor: floor, threshold: threshold, frames: 120) == threshold)
    }

    @Test func speechAfterAPauseInvalidatesTheSpeculation() async throws {
        var script = Self.dictation(words: 10)
        script.silence(0.8) // speculation fires here
        for index in 10..<14 {
            script.word(index)
            script.silence(0.1)
        }
        let outcome = try await Self.run(script.samples, settle: false)
        #expect(outcome.text == script.words.joined(separator: " "))
        #expect(outcome.stats?.speculativeHit == false)
    }

    /// A cut landing just after a speculative pass must not leave the stop without one.
    @Test func cutAfterSpeculationStillEndsInAHit() async throws {
        // ~8.4 s of speech with a sentence pause near the end: the cut lands there after the
        // speculation for it has already gone out.
        var script = Self.dictation(words: 18, sentence: 17, pause: 0.6)
        script.silence(1.2)
        let outcome = try await Self.run(script.samples)
        #expect(outcome.text == script.words.joined(separator: " "))
        #expect(outcome.stats?.speculativeHit == true || outcome.stats?.tailSeconds == 0)
    }

    /// Pause, carry on, stop mid-word: the pass taken at the pause still covers everything before
    /// it, so the stop decodes only the words after it.
    @Test func stopAfterCarryingOnReusesTheLastPause() async throws {
        // Short enough (~7 s) that no regular cut takes the pause first.
        var script = Self.dictation(words: 10, sentence: 100)
        script.silence(0.8) // speculation fires here
        for index in 10..<15 {
            script.word(index)
            script.silence(0.1)
        }
        script.word(98, seconds: 0.15)
        let outcome = try await Self.run(script.samples, settle: false)
        #expect(outcome.text == script.words.joined(separator: " "))
        #expect(outcome.stats?.reusedSpeculation == true)
        // Left context plus the ~2.5 s after the pause, not all ~7 s of the take.
        let left = PauseWindowPipeline.Layout.standard.finalLeftContext
        #expect((outcome.stats?.tailSeconds ?? 99) < left + 3)
    }

    /// Talking straight through and stopping mid-word: a rolling pass taken while speaking
    /// leaves only the last second or so to decode.
    @Test func rollingPassShortensAMidWordStop() async throws {
        // Continuous speech (100 ms gaps) for ~6 s, then a mid-word stop.
        var script = Self.dictation(words: 15, gap: 0.1, sentence: 1_000)
        script.word(97, seconds: 0.15)
        let recognizer = FakeRecognizer()
        let pipeline = PauseWindowPipeline(decode: recognizer.decode)
        var offset = 0
        while offset < script.samples.count {
            let end = min(offset + 4_096, script.samples.count)
            pipeline.append(Array(script.samples[offset..<end]))
            offset = end
            // Real time would give each pass ~256 ms to land before the next buffer.
            try await Task.sleep(for: .milliseconds(5))
        }
        let text = try await pipeline.finish()
        #expect(text == script.words.joined(separator: " "))
        let stats = try #require(pipeline.stats)
        #expect(stats.rollingSpeculations >= 2)
        #expect(stats.reusedSpeculation)
        let layout = PauseWindowPipeline.Layout.standard
        #expect(stats.tailSeconds < layout.finalLeftContext + layout.rollingMargin + (layout.rollingInterval ?? 0) + 0.6)
    }

    /// ⌘⇧ goes down just after the last word; Space lands a moment later. The pass started at
    /// the modifiers must be the one the stop uses.
    @Test func anticipatedStopIsAHit() async throws {
        var script = Self.dictation(words: 20, gap: 0.1, sentence: 1_000)
        script.silence(0.1)
        let recognizer = FakeRecognizer()
        let pipeline = PauseWindowPipeline(decode: recognizer.decode)
        var offset = 0
        while offset < script.samples.count {
            let end = min(offset + 4_096, script.samples.count)
            pipeline.append(Array(script.samples[offset..<end]))
            offset = end
            await Task.yield()
        }
        pipeline.anticipateStop()
        var tail = Script()
        tail.silence(0.15)
        pipeline.append(tail.samples)
        try await Task.sleep(for: .milliseconds(30))
        let before = recognizer.calls
        let text = try await pipeline.finish()
        #expect(text == script.words.joined(separator: " "))
        #expect(pipeline.stats?.anticipated == true)
        #expect(pipeline.stats?.speculativeHit == true)
        #expect(recognizer.calls == before, "the anticipated pass already covered the tail")
    }

    @Test func veryShortTakeWorks() async throws {
        var script = Script()
        script.word(1)
        script.silence(0.4)
        let outcome = try await Self.run(script.samples)
        #expect(outcome.text == "w1")
    }

    @Test func silentTakeIsEmptyAndRunsNoModel() async throws {
        var script = Script()
        script.silence(3)
        let outcome = try await Self.run(script.samples)
        #expect(outcome.text.isEmpty)
        #expect(outcome.totalDecodes == 0)
    }

    @Test func failedWindowFailsTheTakeSoItFallsBack() async throws {
        var script = Self.dictation(words: 60)
        script.silence(0.8)
        // Speculative passes may fail harmlessly; a regular window failing must fail the take.
        let recognizer = FakeRecognizer(failAll: true)
        await #expect(throws: ChunkPipelineFailure.self) {
            _ = try await Self.run(script.samples, recognizer: recognizer)
        }
    }

    @Test func bufferStaysBoundedOnALongTake() async throws {
        let pipeline = PauseWindowPipeline(decode: FakeRecognizer().decode)
        let script = Self.dictation(words: 400) // ~3 minutes
        var offset = 0
        while offset < script.samples.count {
            let end = min(offset + 4_096, script.samples.count)
            pipeline.append(Array(script.samples[offset..<end]))
            offset = end
        }
        #expect(pipeline.bufferedSeconds < 15, "only the current window and its context are kept")
        pipeline.cancel()
    }

    // MARK: - Pure helpers

    @Test func wordsAreAssignedByTheirFirstToken() {
        let tokens = [
            TimedToken(text: " hel", start: 0.9),
            TimedToken(text: "lo", start: 1.05), // continuation past the cut stays with its word
            TimedToken(text: ",", start: 1.1),
            TimedToken(text: " world", start: 1.3),
        ]
        let kept = PauseWindowPipeline.keep(tokens, in: 0..<1.0)
        #expect(kept.map(\.text) == [" hel", "lo", ","])
        let next = PauseWindowPipeline.keep(tokens, in: 1.0..<Double.infinity)
        #expect(next.map(\.text) == [" world"])
    }

    /// The window after a seam heard both sides of it; its punctuation wins.
    @Test func nextWindowDecidesSeamPunctuation() {
        let context = [
            TimedToken(text: " the", start: 4.0),
            TimedToken(text: " release", start: 4.3),
            TimedToken(text: ".", start: 4.7),
            TimedToken(text: " The", start: 5.2),
        ]
        #expect(PauseWindowPipeline.boundary(in: context, before: 5.0) == ".")
        #expect(PauseWindowPipeline.boundary(in: context, before: -.infinity) == nil)
        let text = PauseWindowPipeline.join([
            TranscriptPiece(tokens: [TimedToken(text: " the", start: 4.0), TimedToken(text: " release", start: 4.3), TimedToken(text: ",", start: 4.7)]),
            TranscriptPiece(tokens: [TimedToken(text: " The", start: 5.2), TimedToken(text: " build", start: 5.5)], boundary: "."),
        ])
        #expect(text == "the release. The build")
    }

    @Test func seamDuplicateIsDropped() {
        let text = PauseWindowPipeline.join([
            [TimedToken(text: " one", start: 1), TimedToken(text: " two", start: 2)],
            [TimedToken(text: " Two", start: 2.1), TimedToken(text: " three", start: 3)],
        ])
        #expect(text == "one two three")
    }
}

/// Names each amplitude-coded burst in whatever window it is handed.
final class FakeRecognizer: Sendable {
    static let quietAmplitude: Float = 0.012

    static func amplitude(for index: Int) -> Float {
        0.1 + 0.001 * Float(index)
    }

    private let failAll: Bool
    private let count = Mutex(0)

    init(failAll: Bool = false) {
        self.failAll = failAll
    }

    var calls: Int { count.withLock { $0 } }

    var decode: PauseWindowPipeline.Decode {
        { [self] samples in
            count.withLock { $0 += 1 }
            if failAll { throw FakeError() }
            return Self.recognise(samples)
        }
    }

    struct FakeError: Error {}

    static func recognise(_ samples: [Float]) -> [TimedToken] {
        let rate = Double(AudioResampler.targetSampleRate)
        var tokens: [TimedToken] = []
        var start: Int?
        var peak: Float = 0
        var quietRun = 0
        func close(at end: Int) {
            guard let s = start, end - s >= 160 else { start = nil; return }
            let word: String
            if abs(peak - quietAmplitude) < 0.004 {
                word = "quiet"
            } else if peak >= 0.099 {
                word = "w\(Int(((peak - 0.1) / 0.001).rounded()))"
            } else {
                start = nil
                return
            }
            tokens.append(TimedToken(text: " " + word, start: Double(s) / rate))
            start = nil
        }
        for (index, sample) in samples.enumerated() {
            let level = abs(sample)
            if level > 0.006 {
                if start == nil {
                    start = index
                    peak = 0
                }
                peak = max(peak, level)
                quietRun = 0
            } else if start != nil {
                quietRun += 1
                if quietRun >= 320 {
                    close(at: index - quietRun)
                    quietRun = 0
                }
            }
        }
        if start != nil { close(at: samples.count) }
        return tokens
    }
}
