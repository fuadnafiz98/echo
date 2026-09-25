import Accelerate
import Foundation
import Synchronization

/// One recognised sub-word, placed on the take's own clock.
nonisolated struct TimedToken: Sendable, Equatable {
    /// SentencePiece text with the word boundary already turned into a leading space.
    var text: String
    /// Seconds from the start of the take.
    var start: Double
}

/// One window's share of the transcript.
nonisolated struct TranscriptPiece: Sendable, Equatable {
    var tokens: [TimedToken]
    /// The punctuation this window heard just before its first word (from its left context), or
    /// `nil` if it has no context. It saw both sides of the seam, which the window before only
    /// partly did, so it gets the last word on how the previous piece ends.
    var boundary: String?

    init(tokens: [TimedToken], boundary: String? = nil) {
        self.tokens = tokens
        self.boundary = boundary
    }
}

/// Transcribes a Parakeet take in pause-aligned windows while it is being spoken, so that at stop
/// there is little or nothing left to decode.
///
/// TDT decodes a fixed 15 s block no matter how much audio it is given, so a stop that has to run
/// the model costs ~110 ms plus ~10 ms per second of undecoded speech on an M1 Pro. Two things keep
/// that off the stop path:
///
/// - **Windows.** Audio is cut in the middle of a real pause and each window is decoded with a
///   fresh decoder state, the way FluidAudio's own batch chunking works. Every window also sees
///   `leftContext` seconds before its range and `rightContext` after it, so its first word is not
///   treated as a sentence start and its last word is not treated as the end of the recording.
///   Words are then assigned to exactly one window by the start time of their first token.
/// - **Speculation.** When the speaker pauses, the tail is decoded as though they had just
///   pressed stop. If they do press stop without speaking again, that result is used as is and
///   the stop runs no model at all.
///
/// If any window fails, `finish` throws ``ChunkPipelineFailure`` and the caller transcribes the
/// whole take instead, which is always still available from the collector.
nonisolated final class PauseWindowPipeline: Sendable {
    /// `(samples) -> tokens`, token starts relative to the first sample. Calls are serialised.
    typealias Decode = @Sendable ([Float]) async throws -> [TimedToken]

    /// Context sizes chosen by sweep on synthesised dictation (2026-09-23, M1 Pro): with 1 s of
    /// right context the model could not tell a sentence end from a comma at a cut and misheard
    /// the odd word near it; 2 s matched batch word accuracy exactly and cut seam punctuation
    /// errors from ~5 to ~3 per 95 words. 3 s of left context with ~6 s windows kept the
    /// mid-word stop tail shortest of the accurate layouts.
    nonisolated struct Layout: Sendable, Equatable {
        var leftContext = 3.0
        var rightContext = 2.0
        /// Once this much audio has passed the last cut, start looking for the next one.
        var targetWindow = 6.0
        /// Never cut sooner than this after the previous cut.
        var minWindow = 3.5
        /// No pause by here means a forced cut at the quietest frame.
        var hardCap = 9.9
        var minPause = 0.24
        var speculationPause = 0.3
        /// Speculative decodes cost a model pass each; a hesitant speaker should not burn the ANE.
        var speculationInterval = 1.5
        /// While speech goes on without a pause, also decode the tail this often, so a stop in
        /// the middle of a word only has the last second or so left. `nil` turns it off.
        ///
        /// Swept 2026-09-23 on an M1 Pro: every 3 s gave a 135 ms mid-word stop at 9.9% of a
        /// core while talking; every 1.5 s gave 134 ms at 15%; off gave 167 ms at 6%.
        var rollingInterval: Double? = 3.0
        /// A rolling pass is reused only up to the quietest point this far before its end, so the
        /// word it ends on is never one the pass heard only half of.
        var rollingMargin = 0.4
        /// Left context for the window decoded at stop. Shorter than `leftContext`: this one is
        /// on the user's clock, and ~7 ms per second of audio adds up.
        var finalLeftContext = 1.5

        static let standard = Layout()

        /// The encoder takes at most 15 s; a window is its range plus both contexts.
        var fitsEncoder: Bool {
            leftContext + hardCap + rightContext <= 14.9
        }
    }

    static let sampleRate = AudioResampler.targetSampleRate
    static let frameSamples = 320 // 20 ms
    /// FluidAudio rejects very short input; pad anything below this.
    static let minimumDecodeSamples = Int(sampleRate)
    /// Consecutive loud frames that count as speech. A keyboard click at the hotkey is shorter.
    static let speechRunFrames = 4
    fileprivate static let longAgo = -Int(sampleRate) * 3600

    private enum Kind: Sendable {
        /// Between two cuts; committed in order.
        case regular
        /// The tail decoded at a pause, in case stop comes next.
        case speculative
        /// Decoded at stop.
        case final
    }

    private struct Window: Sendable {
        var id: Int
        var samples: [Float]
        /// Absolute sample index of `samples[0]`.
        var offset: Int
        /// Absolute seconds. Words whose first token starts here belong to this window.
        var keep: Range<Double>
        var kind: Kind
        /// For a speculative window, what it speculates on.
        var speculation: Speculation?
    }

    private struct Speculation: Sendable {
        var id: Int
        var lastCut: Int
        var tailEnd: Int
        /// Where its words stop being trusted if the speaker carries on: the middle of the pause
        /// it was taken in, or for a rolling pass the quietest point just before its end. A stop
        /// then only decodes from here on.
        var pauseMid: Int
        /// Taken while speech was still going, so never usable as the whole tail.
        var rolling = false
        /// Speech came after it; usable only up to `pauseMid`.
        var stale = false
        var tokens: TranscriptPiece?
    }

    private struct State {
        var buffer: [Float] = []
        var bufferStart = 0
        /// RMS per 20 ms frame, aligned with `buffer` (frame 0 is `bufferStart`).
        var energies: [Float] = []
        var total = 0
        var lastCut = 0
        var threshold: Float = 0.01
        /// Higher than `threshold` on a quiet mic; decides what is speech, never where to cut.
        var speechThreshold: Float = 0.01
        var noiseFloor: Float = 0
        var framesSinceThreshold = Int.max
        var aboveRun = 0
        /// Absolute sample index just after the last confirmed speech frame; -1 before any.
        var lastSpeechEnd = -1
        var lastPauseSpeculationAt = PauseWindowPipeline.longAgo
        var lastRollingAt = PauseWindowPipeline.longAgo
        /// The newest speculative pass, finished or not.
        var speculation: Speculation?
        /// The newest pass that has finished, for reuse when the newest one is still running.
        var completed: Speculation?
        var committed: [TranscriptPiece] = []
        var finalTokens: TranscriptPiece?
        var finalDecodeSeconds = 0.0
        var nextWindowID = 0
        var pendingWindows = 0
        var failed = false
        var finished = false
        var cuts = 0
        var forcedCuts = 0
        var speculations = 0
        var rollingSpeculations = 0
        var anticipated = false
        /// Between the stop shortcut's modifiers and its key: keep passes going back to back.
        var anticipating = false
        var anticipationChain = 0
        /// Which way stop went, and why a pass did not cover the tail. Diagnostics only.
        var stopPath = ""
    }

    struct Stats: Sendable {
        var cuts: Int
        var forcedCuts: Int
        var speculations: Int
        var rollingSpeculations: Int
        /// The stop shortcut's modifiers were seen before the stop itself.
        var anticipated: Bool
        /// Seconds of speech the stop had to decode; 0 when speculation or a cut covered it.
        var tailSeconds: Double
        var speculativeHit: Bool
        /// A stale speculation covered the tail up to its pause, so stop decoded only after it.
        var reusedSpeculation: Bool
        /// Wall time of `finish`, and how much of it was the final decode itself. The rest was
        /// waiting for work that was already running when stop came.
        var finishMilliseconds: Double
        var finalDecodeMilliseconds: Double
        /// `ready`, `waitPass`, `nothing`, or `reuse`/`decode` plus why no pass covered the tail.
        var stopPath: String
    }

    /// Shared with the worker task, which cannot capture `self` from `init`.
    private final class Core: Sendable {
        let state = Mutex(State())
        let stats = Mutex<Stats?>(nil)
        /// The speculative decode in flight, so stop can cancel one it has no use for.
        let running = Mutex<(id: Int, task: Task<TranscriptPiece, Error>)?>(nil)
    }

    private let layout: Layout
    private let decode: Decode
    private let core = Core()
    private let jobs: AsyncStream<Window>.Continuation
    private let worker: Task<Void, Never>

    init(layout: Layout = .standard, decode: @escaping Decode) {
        precondition(layout.fitsEncoder, "window plus context must fit the 15 s encoder")
        self.layout = layout
        self.decode = decode
        let (stream, continuation) = AsyncStream<Window>.makeStream(bufferingPolicy: .unbounded)
        jobs = continuation
        let core = core
        let layout = layout
        // One consumer, so decodes run one at a time and in order.
        worker = Task(priority: .userInitiated) {
            for await window in stream {
                if window.kind == .speculative {
                    let current = core.state.withLock { $0.speculation?.id == window.id && !$0.failed }
                    guard current else { continue }
                }
                do {
                    let tokens: TranscriptPiece
                    if window.kind == .speculative {
                        let task = Task { try await Self.run(window, decode: decode) }
                        core.running.withLock { $0 = (window.id, task) }
                        defer { core.running.withLock { $0 = nil } }
                        tokens = try await task.value
                    } else {
                        let started = CFAbsoluteTimeGetCurrent()
                        tokens = try await Self.run(window, decode: decode)
                        if window.kind == .final {
                            let seconds = CFAbsoluteTimeGetCurrent() - started
                            core.state.withLock { $0.finalDecodeSeconds = seconds }
                        }
                    }
                    core.state.withLock { s in
                        switch window.kind {
                        case .speculative:
                            if s.speculation?.id == window.id {
                                s.speculation?.tokens = tokens
                            }
                            if var done = window.speculation, done.lastCut == s.lastCut,
                               (s.completed?.id ?? -1) < done.id {
                                done.tokens = tokens
                                s.completed = done
                            }
                        case .regular:
                            s.committed.append(tokens)
                            s.pendingWindows -= 1
                        case .final:
                            s.finalTokens = tokens
                            s.pendingWindows -= 1
                        }
                    }
                    // Waiting for Space: go again at once. Each pass covers a little more, and
                    // back-to-back passes keep the CPU clocked up for the one stop will need.
                    if window.kind == .speculative,
                       let next = core.state.withLock({ Self.chainAnticipation(&$0, layout: layout) }) {
                        continuation.yield(next)
                    }
                } catch {
                    core.state.withLock { s in
                        if window.kind == .speculative {
                            if s.speculation?.id == window.id { s.speculation = nil }
                        } else {
                            s.failed = true
                            s.pendingWindows -= 1
                        }
                    }
                    if window.kind != .speculative {
                        Latency.note("parakeet window failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    deinit {
        jobs.finish()
        worker.cancel()
    }

    var frameCount: Int {
        core.state.withLock { $0.total }
    }

    /// Audio still held. Bounded by one window plus its context, however long the take.
    var bufferedSeconds: Double {
        core.state.withLock { Double($0.buffer.count) / Self.sampleRate }
    }

    var stats: Stats? {
        core.stats.withLock { $0 }
    }

    /// Everything captured was fed in, give or take the collector's last partial drain.
    func sawAtLeast(frames expected: Int) -> Bool {
        guard expected > 0 else { return true }
        return frameCount + Int(0.75 * Self.sampleRate) >= expected
    }

    // MARK: - Audio in

    /// Collector IO queue. Never awaits and never runs the model.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        // Yielded inside the lock: a window decided here must not land after `finish` has
        // closed the queue. `yield` on an unbounded stream never blocks.
        core.state.withLock { s in
            guard !s.finished, !s.failed else { return }
            let firstNewFrame = s.energies.count
            s.buffer.append(contentsOf: samples)
            s.total += samples.count
            Self.measureFrames(&s)
            Self.trackSpeech(&s, from: firstNewFrame, layout: layout)

            while let window = Self.nextCut(&s, layout: layout) {
                jobs.yield(window)
            }
            if let speculative = Self.speculate(&s, layout: layout) {
                jobs.yield(speculative)
            }
        }
    }

    /// The user is reaching for the stop shortcut: decode the tail now, whatever the timers say,
    /// and keep decoding it back to back until the stop comes.
    ///
    /// Measured on an M1 Pro, a decode that follows even a quarter second of idle runs ~30 ms
    /// slower (135 vs 103 ms for 2.7 s of audio) because the CPU has clocked down; keeping passes
    /// going until stop means the one that matters starts warm, or is not needed at all.
    func anticipateStop() {
        core.state.withLock { s in
            guard !s.finished, !s.failed else { return }
            s.anticipated = true
            s.anticipating = true
            s.anticipationChain = 0
            guard s.lastSpeechEnd > s.lastCut else { return }
            // A pause pass that already covers everything heard is as good as a new one.
            if let speculation = s.speculation, !speculation.stale, speculation.lastCut == s.lastCut,
               speculation.tailEnd >= s.lastSpeechEnd {
                return
            }
            jobs.yield(Self.anticipationWindow(&s, layout: layout))
        }
    }

    private static func chainAnticipation(_ s: inout State, layout: Layout) -> Window? {
        guard s.anticipating, !s.finished, !s.failed, s.anticipationChain < 4,
              s.lastSpeechEnd > s.lastCut,
              s.total - (s.speculation?.tailEnd ?? 0) >= seconds(0.05)
        else { return nil }
        s.anticipationChain += 1
        return anticipationWindow(&s, layout: layout)
    }

    private static func anticipationWindow(_ s: inout State, layout: Layout) -> Window {
        let quiet = s.total - s.lastSpeechEnd
        let pauseMid: Int
        if quiet >= seconds(0.2) {
            pauseMid = s.lastSpeechEnd + quiet / 2
        } else {
            let to = s.total - seconds(layout.rollingMargin)
            let from = max(s.lastCut + seconds(0.5), to - seconds(0.5))
            pauseMid = to > from ? quietestPoint(in: s, from: from, to: to) : s.lastCut
        }
        // Not stale: if nothing audible follows, this is the whole tail.
        var window = makeWindow(&s, from: s.lastCut, to: nil, end: s.total, layout: layout, kind: .speculative)
        let speculation = Speculation(id: window.id, lastCut: s.lastCut, tailEnd: s.total, pauseMid: pauseMid)
        window.speculation = speculation
        s.speculation = speculation
        s.speculations += 1
        return window
    }

    // MARK: - Stop

    /// Waits for outstanding windows, decodes whatever speech is left and returns the transcript.
    func finish() async throws -> String {
        let finishStarted = CFAbsoluteTimeGetCurrent()
        let (plan, backlog): (Plan, Int) = core.state.withLock { s in
            s.finished = true
            let plan = Self.finalPlan(&s, layout: layout)
            switch plan {
            case .decode(let window), .reuse(_, _, let window):
                jobs.yield(window)
            case .nothing, .speculation, .ready:
                break
            }
            jobs.finish()
            return (plan, s.pendingWindows)
        }
        // A speculative decode still running is only worth finishing if it is the tail.
        let needed: Int? = core.state.withLock { s in
            if case .speculation = plan { return s.speculation?.id }
            return nil
        }
        core.running.withLock { running in
            if let running, running.id != needed {
                running.task.cancel()
            }
        }
        // Tens of seconds undecoded (a cold model, say): the whole-take path decodes in parallel
        // and beats draining this queue one window at a time.
        if backlog >= 4 {
            cancel()
            throw ChunkPipelineFailure()
        }
        await worker.value

        // The speculative pass it relied on failed or was dropped: decode the whole tail now.
        let fallback: Window? = core.state.withLock { s in
            guard !s.failed, case .speculation = plan, s.speculation?.tokens == nil else { return nil }
            switch plan {
            case .speculation:
                return Self.makeWindow(&s, from: s.lastCut, to: nil, end: s.total, layout: layout, kind: .final)
            case .nothing, .decode, .reuse, .ready:
                return nil
            }
        }
        var fallbackTokens: TranscriptPiece?
        if let fallback {
            fallbackTokens = try await Self.run(fallback, decode: decode)
        }

        let (result, stats): (Result<String, ChunkPipelineFailure>, Stats) = core.state.withLock { s in
            var pieces = s.committed
            var tail = 0.0
            var hit = false
            var reused = false
            if let fallback, let fallbackTokens {
                tail = Double(fallback.samples.count) / Self.sampleRate
                pieces.append(fallbackTokens)
            } else {
                switch plan {
                case .nothing:
                    break
                case .speculation:
                    hit = true
                    pieces.append(s.speculation?.tokens ?? TranscriptPiece(tokens: []))
                case .ready(let tokens):
                    hit = true
                    pieces.append(tokens)
                case .reuse(let until, let tokens, let window):
                    reused = true
                    tail = Double(window.samples.count) / Self.sampleRate
                    let start = s.lastCut == 0 ? -Double.infinity : Double(s.lastCut) / Self.sampleRate
                    let upTo = Double(until) / Self.sampleRate
                    pieces.append(TranscriptPiece(tokens: Self.keep(tokens.tokens, in: start..<upTo), boundary: tokens.boundary))
                    pieces.append(s.finalTokens ?? TranscriptPiece(tokens: []))
                case .decode(let window):
                    tail = Double(window.samples.count) / Self.sampleRate
                    pieces.append(s.finalTokens ?? TranscriptPiece(tokens: []))
                }
            }
            let stats = Stats(
                cuts: s.cuts,
                forcedCuts: s.forcedCuts,
                speculations: s.speculations,
                rollingSpeculations: s.rollingSpeculations,
                anticipated: s.anticipated,
                tailSeconds: tail,
                speculativeHit: hit,
                reusedSpeculation: reused,
                finishMilliseconds: (CFAbsoluteTimeGetCurrent() - finishStarted) * 1_000,
                finalDecodeMilliseconds: s.finalDecodeSeconds * 1_000,
                stopPath: s.stopPath
            )
            if s.failed { return (.failure(ChunkPipelineFailure()), stats) }
            return (.success(Self.join(pieces)), stats)
        }
        core.stats.withLock { $0 = stats }
        return try result.get()
    }

    /// Abandons queued work. Safe from a cancellation path.
    func cancel() {
        core.state.withLock { s in
            s.finished = true
            s.failed = true
            s.buffer = []
            s.energies = []
        }
        jobs.finish()
        worker.cancel()
    }

    // MARK: - Decisions (all under the lock)

    private static func measureFrames(_ s: inout State) {
        let available = s.buffer.count / frameSamples
        guard available > s.energies.count else { return }
        s.buffer.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for frame in s.energies.count..<available {
                var rms: Float = 0
                vDSP_rmsqv(base + frame * frameSamples, 1, &rms, vDSP_Length(frameSamples))
                s.energies.append(rms)
            }
        }
    }

    /// Adaptive quiet threshold from this buffer's own noise floor and speech level.
    ///
    /// With under three seconds of history the quietest frames may all be speech (people start
    /// talking as they press the hotkey), so the floor is capped at a typical microphone's until
    /// real silence has been heard.
    static func threshold(for energies: [Float]) -> (floor: Float, threshold: Float) {
        guard energies.count >= 10 else { return (0, 0.01) }
        let sorted = energies.sorted()
        var floor = sorted[sorted.count / 10]
        if energies.count < 150 {
            floor = min(floor, 0.008)
        }
        let peak = sorted[sorted.count * 9 / 10]
        return (floor, max(0.002, floor + (peak - floor) * 0.12))
    }

    /// The level that counts as speech, as opposed to `threshold`, which only picks cut points.
    ///
    /// A quiet mic puts speech 10–15 dB above the floor, and 12% of that gap sits inside the
    /// noise's own flicker: real takes at a 0.002 floor saw "speech" after their last word and
    /// threw away a finished pass. Speech must clear the floor by 6 dB; `audible`, halfway
    /// between, still catches a soft last syllable. Cuts keep the lower threshold: moving them
    /// changes the transcript (swept on real takes 2026-09-24: 61 → 83 words off batch). Not in
    /// the first 3 s, where the "floor" may be speech itself and is capped.
    static func speechThreshold(floor: Float, threshold: Float, frames: Int) -> Float {
        frames < 150 ? threshold : max(threshold, floor * 2)
    }

    /// Anything that might be a word after `sample`: a laxer test than speech tracking, because a
    /// false positive costs one decode and a false negative drops the user's last words.
    private static func audible(_ s: State, since sample: Int, until end: Int? = nil) -> Bool {
        let first = max(0, (sample - s.bufferStart) / frameSamples)
        let last = min(s.energies.count, end.map { max(0, ($0 - s.bufferStart) / frameSamples) } ?? s.energies.count)
        guard first < last else { return false }
        let lax = s.noiseFloor + (s.speechThreshold - s.noiseFloor) * 0.5
        var run = 0
        for frame in first..<last {
            if s.energies[frame] > lax {
                run += 1
                if run >= 3 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    /// Where a key click at the very end of the take starts, if there is one: a burst of at most
    /// `clickFrames` that follows at least `clickQuietFrames` of quiet. Speech running into the
    /// stop has no quiet before its last frames, so it never matches.
    static let clickFrames = 6
    static let clickQuietFrames = 3

    private static func stopClick(_ s: State) -> Int? {
        let lax = s.noiseFloor + (s.speechThreshold - s.noiseFloor) * 0.5
        let e = s.energies
        var frame = e.count - 1
        while frame >= 0, e[frame] <= lax, e.count - frame <= clickFrames { frame -= 1 }
        var loud = 0
        while frame >= 0, e[frame] > lax { loud += 1; frame -= 1 }
        guard loud > 0, e.count - 1 - frame <= clickFrames else { return nil }
        var quiet = 0
        while frame >= 0, e[frame] <= lax, quiet < clickQuietFrames { quiet += 1; frame -= 1 }
        guard quiet >= clickQuietFrames else { return nil }
        return s.bufferStart + (frame + 1 + quiet) * frameSamples
    }

    /// The end of the last run of speech that finishes before `sample`.
    private static func lastSpeechEnd(_ s: State, before sample: Int) -> Int {
        let limit = min(s.energies.count, max(0, (sample - s.bufferStart) / frameSamples))
        var run = 0
        var frame = limit - 1
        while frame >= 0 {
            if s.energies[frame] > s.speechThreshold {
                run += 1
                if run >= speechRunFrames { return s.bufferStart + (frame + run) * frameSamples }
            } else {
                run = 0
            }
            frame -= 1
        }
        return min(s.lastSpeechEnd, s.bufferStart)
    }

    private static func trackSpeech(_ s: inout State, from firstNewFrame: Int, layout: Layout) {
        if s.framesSinceThreshold >= (s.energies.count < 150 ? 10 : 50) {
            (s.noiseFloor, s.threshold) = threshold(for: s.energies)
            s.speechThreshold = speechThreshold(floor: s.noiseFloor, threshold: s.threshold, frames: s.energies.count)
            s.framesSinceThreshold = 0
        }
        guard firstNewFrame < s.energies.count else { return }
        s.framesSinceThreshold += s.energies.count - firstNewFrame
        for frame in firstNewFrame..<s.energies.count {
            if s.energies[frame] > s.speechThreshold {
                s.aboveRun += 1
                if s.aboveRun >= speechRunFrames {
                    s.lastSpeechEnd = s.bufferStart + (frame + 1) * frameSamples
                    // New speech after a pause makes the speculative tail stale; it stays useful
                    // up to its pause.
                    if let speculation = s.speculation, s.lastSpeechEnd > speculation.tailEnd {
                        s.speculation?.stale = true
                    }
                }
            } else {
                s.aboveRun = 0
            }
        }
    }

    /// The next regular window, if the audio has reached a point where a cut can be chosen.
    private static func nextCut(_ s: inout State, layout: Layout) -> Window? {
        let right = seconds(layout.rightContext)
        guard s.total >= s.lastCut + seconds(layout.targetWindow) + right else { return nil }

        let searchFrom = s.lastCut + seconds(layout.minWindow)
        let searchTo = min(s.total - right, s.lastCut + seconds(layout.hardCap))
        guard searchTo > searchFrom else { return nil }

        let cut: Int
        let forced: Bool
        if let pause = bestPause(in: s, from: searchFrom, to: searchTo, layout: layout) {
            cut = pause
            forced = false
        } else if s.total - right >= s.lastCut + seconds(layout.hardCap) {
            cut = quietestPoint(in: s, from: searchFrom, to: searchTo)
            forced = true
        } else {
            return nil
        }

        let window = makeWindow(&s, from: s.lastCut, to: cut, end: cut + right, layout: layout, kind: .regular)
        s.lastCut = cut
        s.cuts += 1
        if forced { s.forcedCuts += 1 }
        s.pendingWindows += 1
        // The next window's left context is all that is still needed from before the cut. A cut
        // moves the tail's start, so any speculation is stale and a fresh one may go out at once.
        s.speculation = nil
        s.completed = nil
        s.lastPauseSpeculationAt = longAgo
        s.lastRollingAt = longAgo
        trim(&s, keepingFrom: cut - seconds(layout.leftContext))
        return window
    }

    /// When the speaker has just paused, decode the tail as though they had pressed stop. While
    /// they keep talking, decode it every `rollingInterval` anyway, so a stop mid-word has only
    /// the last moment left.
    private static func speculate(_ s: inout State, layout: Layout) -> Window? {
        guard s.lastSpeechEnd > s.lastCut else { return nil }
        let quiet = s.total - s.lastSpeechEnd

        if quiet >= seconds(layout.speculationPause) {
            if let speculation = s.speculation, !speculation.rolling, speculation.lastCut == s.lastCut,
               speculation.tailEnd >= s.lastSpeechEnd {
                return nil
            }
            guard s.total - s.lastPauseSpeculationAt >= seconds(layout.speculationInterval) else { return nil }
            s.lastPauseSpeculationAt = s.total
            return issueSpeculation(&s, pauseMid: s.lastSpeechEnd + quiet / 2, rolling: false, layout: layout)
        }

        guard let interval = layout.rollingInterval else { return nil }
        let since = max(s.lastRollingAt, s.lastPauseSpeculationAt, s.lastCut)
        guard s.total - since >= seconds(interval) else { return nil }
        let to = s.total - seconds(layout.rollingMargin)
        let from = max(s.lastCut + seconds(0.5), to - seconds(0.5))
        guard to > from else { return nil }
        let dip = quietestPoint(in: s, from: from, to: to)
        s.lastRollingAt = s.total
        return issueSpeculation(&s, pauseMid: dip, rolling: true, layout: layout)
    }

    private static func issueSpeculation(_ s: inout State, pauseMid: Int, rolling: Bool, layout: Layout) -> Window {
        var window = makeWindow(&s, from: s.lastCut, to: nil, end: s.total, layout: layout, kind: .speculative)
        let speculation = Speculation(
            id: window.id,
            lastCut: s.lastCut,
            tailEnd: s.total,
            pauseMid: pauseMid,
            rolling: rolling,
            stale: rolling
        )
        window.speculation = speculation
        s.speculation = speculation
        s.speculations += 1
        if rolling { s.rollingSpeculations += 1 }
        return window
    }

    private enum Plan {
        /// Nothing audible since the last cut.
        case nothing
        /// A speculative pass covers the tail; use it once it lands.
        case speculation
        /// A finished speculative pass covers the tail; use it now.
        case ready(TranscriptPiece)
        /// A finished speculative pass covers the tail up to `until`; decode only the rest.
        case reuse(until: Int, tokens: TranscriptPiece, Window)
        case decode(Window)
    }

    /// What stop still has to decode.
    private static func finalPlan(_ s: inout State, layout: Layout) -> Plan {
        // Nothing audible since the last cut: the committed windows are the whole transcript.
        guard s.lastSpeechEnd > s.lastCut || audible(s, since: s.lastCut) else {
            s.speculation = nil
            s.stopPath = "nothing"
            return .nothing
        }
        // The stop key's own click lands in the last few frames; it is not a word.
        let click = stopClick(s)
        let speechEnd = click.map { lastSpeechEnd(s, before: $0) } ?? s.lastSpeechEnd
        let soundEnd = click ?? s.total
        func covers(_ speculation: Speculation) -> Bool {
            speculation.lastCut == s.lastCut && !speculation.rolling
                && speechEnd <= speculation.tailEnd
                && !audible(s, since: speculation.tailEnd, until: soundEnd)
        }
        // A finished pass that already covers everything audible beats waiting for a newer one.
        if let done = s.completed, let tokens = done.tokens, covers(done) {
            s.speculation = nil
            s.stopPath = "ready"
            return .ready(tokens)
        }
        // `covers` rules out speech after the pass, which is all `stale` records besides a click.
        if let speculation = s.speculation, covers(speculation) {
            s.stopPath = "waitPass"
            return .speculation
        }
        let miss: String = {
            guard let latest = s.speculation ?? s.completed else { return "noPass" }
            if latest.lastCut != s.lastCut { return "passBeforeCut" }
            if latest.rolling { return "rollingOnly" }
            if speechEnd > latest.tailEnd { return "speechAfterPass" }
            if audible(s, since: latest.tailEnd, until: soundEnd) { return "soundAfterPass" }
            return latest.stale ? "stale" : "other"
        }()
        // Reuse only a pass that has already finished: waiting for one still running and then
        // decoding the rest would cost more than decoding the whole tail now.
        let candidates = [s.speculation, s.completed].compactMap { $0 }
        let usable = candidates.first { $0.tokens != nil && $0.lastCut == s.lastCut && $0.pauseMid > s.lastCut }
        // Anything still queued is now pointless; the worker skips it.
        s.speculation = nil
        s.pendingWindows += 1
        var stopLayout = layout
        stopLayout.leftContext = layout.finalLeftContext
        s.stopPath = (usable?.tokens != nil ? "reuse:" : "decode:") + miss
        if let usable, let tokens = usable.tokens {
            let window = makeWindow(&s, from: usable.pauseMid, to: nil, end: s.total, layout: stopLayout, kind: .final)
            return .reuse(until: usable.pauseMid, tokens: tokens, window)
        }
        return .decode(makeWindow(&s, from: s.lastCut, to: nil, end: s.total, layout: stopLayout, kind: .final))
    }

    private static func makeWindow(
        _ s: inout State,
        from start: Int,
        to cut: Int?,
        end: Int,
        layout: Layout,
        kind: Kind
    ) -> Window {
        let contextStart = max(s.bufferStart, start - seconds(layout.leftContext))
        let lower = contextStart - s.bufferStart
        let upper = min(s.buffer.count, end - s.bufferStart)
        var samples = Array(s.buffer[lower..<max(lower, upper)])
        if samples.count < minimumDecodeSamples {
            samples.append(contentsOf: [Float](repeating: 0, count: minimumDecodeSamples - samples.count))
        }
        let keepStart = start == 0 ? -Double.infinity : Double(start) / sampleRate
        let keepEnd = cut.map { Double($0) / sampleRate } ?? .infinity
        s.nextWindowID += 1
        return Window(
            id: s.nextWindowID,
            samples: samples,
            offset: contextStart,
            keep: keepStart..<keepEnd,
            kind: kind,
            speculation: nil
        )
    }

    /// Middle of the longest quiet run of at least `minPause` inside `[from, to)`.
    private static func bestPause(in s: State, from: Int, to: Int, layout: Layout) -> Int? {
        let firstFrame = max(0, (from - s.bufferStart) / frameSamples)
        let lastFrame = min(s.energies.count, (to - s.bufferStart) / frameSamples)
        guard lastFrame > firstFrame else { return nil }
        let minFrames = Int((layout.minPause / 0.02).rounded(.up))
        let target = s.lastCut + seconds(layout.targetWindow)

        var best: (length: Int, center: Int)?
        var runStart: Int?
        func close(_ end: Int) {
            guard let start = runStart else { return }
            let length = end - start
            if length >= minFrames {
                let center = s.bufferStart + (start + length / 2) * frameSamples
                if let current = best {
                    if length > current.length
                        || (length == current.length && abs(center - target) < abs(current.center - target)) {
                        best = (length, center)
                    }
                } else {
                    best = (length, center)
                }
            }
            runStart = nil
        }
        for frame in firstFrame..<lastFrame {
            if s.energies[frame] <= s.threshold {
                if runStart == nil { runStart = frame }
            } else {
                close(frame)
            }
        }
        close(lastFrame)
        return best?.center
    }

    private static func quietestPoint(in s: State, from: Int, to: Int) -> Int {
        let firstFrame = max(0, (from - s.bufferStart) / frameSamples)
        let lastFrame = min(s.energies.count, (to - s.bufferStart) / frameSamples)
        guard lastFrame > firstFrame else { return to }
        var bestFrame = firstFrame
        for frame in firstFrame..<lastFrame where s.energies[frame] < s.energies[bestFrame] {
            bestFrame = frame
        }
        return s.bufferStart + bestFrame * frameSamples + frameSamples / 2
    }

    /// Drops audio nothing will read again. Frame-aligned so `energies` stays in step.
    private static func trim(_ s: inout State, keepingFrom sample: Int) {
        let frames = max(0, (sample - s.bufferStart) / frameSamples)
        guard frames > 0 else { return }
        let drop = min(frames * frameSamples, s.buffer.count - s.buffer.count % frameSamples)
        guard drop > 0 else { return }
        s.buffer.removeFirst(drop)
        s.energies.removeFirst(drop / frameSamples)
        s.bufferStart += drop
    }

    private static func seconds(_ value: Double) -> Int {
        Int(value * sampleRate)
    }

    // MARK: - Decode and join

    private static func run(_ window: Window, decode: Decode) async throws -> TranscriptPiece {
        let offset = Double(window.offset) / sampleRate
        let tokens = try await decode(window.samples).map {
            TimedToken(text: $0.text, start: $0.start + offset)
        }
        return TranscriptPiece(
            tokens: keep(tokens, in: window.keep),
            boundary: boundary(in: tokens, before: window.keep.lowerBound)
        )
    }

    /// Trailing punctuation of the last context word before `start`; `nil` without context.
    static func boundary(in tokens: [TimedToken], before start: Double) -> String? {
        guard start.isFinite else { return nil }
        var word: String?
        for (index, token) in tokens.enumerated() where token.start < start {
            if index == 0 || token.text.hasPrefix(" ") {
                word = token.text
            } else {
                word? += token.text
            }
        }
        guard let word else { return nil }
        return String(word.reversed().prefix { sentencePunctuation.contains($0) }.reversed())
    }

    private static let sentencePunctuation: Set<Character> = [".", ",", "?", "!", ";", ":"]

    /// Words, not tokens, are assigned to a window: a word belongs where its first token starts,
    /// and its continuation pieces and trailing punctuation go with it.
    static func keep(_ tokens: [TimedToken], in range: Range<Double>) -> [TimedToken] {
        var kept: [TimedToken] = []
        var keeping = false
        for (index, token) in tokens.enumerated() {
            if index == 0 || token.text.hasPrefix(" ") {
                keeping = range.contains(token.start)
            }
            if keeping {
                kept.append(token)
            }
        }
        return kept
    }

    static func join(_ pieces: [[TimedToken]]) -> String {
        join(pieces.map { TranscriptPiece(tokens: $0) })
    }

    static func join(_ pieces: [TranscriptPiece]) -> String {
        var words: [(text: String, start: Double)] = []
        for piece in pieces {
            var pieceWords: [(text: String, start: Double)] = []
            for token in piece.tokens {
                if pieceWords.isEmpty || token.text.hasPrefix(" ") {
                    pieceWords.append((token.text, token.start))
                } else {
                    pieceWords[pieceWords.count - 1].text += token.text
                }
            }
            // Guard the seam: the same word claimed by both windows within a quarter second.
            if let last = words.last, let first = pieceWords.first,
               normalized(last.text) == normalized(first.text), abs(first.start - last.start) < 0.25 {
                pieceWords.removeFirst()
            } else if let boundary = piece.boundary, !pieceWords.isEmpty, !words.isEmpty {
                // The window after the seam decides how the one before it ends.
                var last = words[words.count - 1].text
                while let character = last.last, sentencePunctuation.contains(character) {
                    last.removeLast()
                }
                words[words.count - 1].text = last + boundary
            }
            words.append(contentsOf: pieceWords)
        }
        let text = words.map(\.text).joined()
        return text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
