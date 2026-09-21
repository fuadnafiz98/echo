import AVFoundation
import os
import Speech

/// Streams audio into `SpeechAnalyzer` while the user talks.
///
/// The old shape wrote a CAF and ran `analyzeSequence(from:)` after stop, so recognition cost was
/// linear in take length — roughly 3 ms per spoken word, which is a second on a long paragraph and
/// several on a multi-minute take. Feeding the analyzer live means the only work left at stop is
/// whatever audio has not been analysed yet, a few hundred milliseconds regardless of length.
///
/// The CAF is still written, but only as a fallback input if streaming produced nothing.
nonisolated final class AppleSTTProvider: TranscriptionProvider, BatchAudioConsumer, FileAudioConsumer,
                                          StreamingAudioConsumer, @unchecked Sendable {
    /// Escape hatch: `defaults write com.fuadnafiz98.echo echo.appleBatchFallback -bool YES`
    /// restores the pre-streaming behaviour.
    static var forceBatchPath: Bool {
        UserDefaults.standard.bool(forKey: "echo.appleBatchFallback")
    }

    /// Whether the most recent take was served by the streaming path. Reported in the latency log
    /// so a silent fall back to batch is visible rather than assumed.
    private static let streamedFlag = OSAllocatedUnfairLock(initialState: false)

    static var lastTakeWasStreamed: Bool {
        streamedFlag.withLock { $0 }
    }

    private let sessionLock = NSLock()
    private var capture: AudioCaptureSnapshot?
    private var fileURL: URL?
    private var vocabularyHints: [String] = []
    private var partialContinuation: AsyncStream<String>.Continuation?
    private var analyzing = false

    private var preparedTranscriber: SpeechTranscriber?
    private var preparedAnalyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<AttributedString, Never>?

    /// Live input sequence into the analyzer. Non-nil only between a successful `start` and `stop`.
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var streaming = false
    private var streamedFrames = 0
    private var streamConverter: StreamingResampler?
    /// Set if the backlog overflowed, so the take falls back rather than pasting a truncated one.
    private var droppedEarlyAudio = false
    /// Audio captured before the analyzer finished starting up.
    ///
    /// The engine starts as soon as the hotkey is pressed, but building the analyzer takes a
    /// moment. Without this, the opening words of every take would be missing from the streamed
    /// transcript.
    ///
    /// Bounded by duration rather than by number of buffers: a drained buffer is one resampled tap
    /// callback, so it is tens of milliseconds, not a fixed slice. Counting buffers would cap this
    /// at a few seconds by accident.
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var pendingFrames = 0
    private static let maxPendingFrames = Int(AudioResampler.targetSampleRate) * 120

    private static let cacheLock = NSLock()
    private static var cachedLocale: Locale?
    private static var assetsReady = false
    private static var reservedLocale: Locale?

    private static let warmLock = NSLock()
    private static var warmTranscriber: SpeechTranscriber?
    private static var warmAnalyzer: SpeechAnalyzer?
    private static var warmFormat: AVAudioFormat?
    private static var prewarmTask: Task<Void, Never>?
    private static var prewarmGeneration: UInt64 = 0

    /// Keeps the on-device speech model mapped for the lifetime of the process.
    ///
    /// With `.whileInUse` the model is dropped whenever no analyzer holds it, so the first take
    /// after an idle stretch pays a full model load. That was the "randomly takes ages" report.
    private static let analyzerOptions = SpeechAnalyzer.Options(
        priority: .userInitiated,
        modelRetention: .processLifetime
    )

    func setVocabularyHints(_ hints: [String]) {
        sessionLock.lock()
        vocabularyHints = hints
        let live = streaming ? preparedAnalyzer : nil
        sessionLock.unlock()

        // Hints arrive from the async frontmost-app scan, usually after analysis has started.
        // The batch path used to pick them up at stop; streaming has to push them in.
        guard let live, !hints.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = Array(hints.prefix(100))
        Task { try? await live.setContext(context) }
    }

    var partialTranscript: AsyncStream<String> {
        AsyncStream { [weak self] continuation in
            guard let self else { return }
            self.sessionLock.lock()
            self.partialContinuation = continuation
            self.sessionLock.unlock()
        }
    }

    func startStreaming() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status != .authorized {
            let requested = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            guard requested == .authorized else {
                throw TranscriptionError.notAuthorized
            }
        }
        try await prepareAnalyzerWork()

        guard !Self.forceBatchPath else { return }
        await beginLiveInput()
    }

    /// Opens the analyzer's input sequence. A failure here is not fatal: the take falls back to
    /// analysing the CAF at stop, which is what the app did before streaming existed.
    private func beginLiveInput() async {
        sessionLock.lock()
        let analyzer = preparedAnalyzer
        let format = analyzerFormat
        sessionLock.unlock()
        guard let analyzer else { return }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .unbounded
        )

        // The collector hands us 16 kHz mono float. If the analyzer negotiated something else,
        // convert on the way in with one long-lived converter.
        var converter: StreamingResampler?
        if let format, !Self.matchesCaptureFormat(format) {
            let resampler = StreamingResampler(outputFormat: format)
            resampler.prepare(inputFormat: AudioResampler.mono16kFormat())
            converter = resampler
            Latency.note("apple analyzer wants \(format) — converting capture audio on the way in")
        }

        // Go live before awaiting `start`. The stream buffers without bound, so audio that
        // arrives while the analyzer is spinning up is queued rather than dropped.
        //
        // The backlog is flushed inside the same critical section that sets `streaming`: a buffer
        // arriving on the IO queue must not overtake it, and `StreamingResampler` is not safe to
        // enter from two threads at once.
        sessionLock.lock()
        inputContinuation = continuation
        streamConverter = converter
        streaming = true
        let backlog = pendingBuffers
        pendingBuffers = []
        pendingFrames = 0
        for buffered in backlog {
            yieldLocked(buffered, through: converter, into: continuation)
        }
        sessionLock.unlock()

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            sessionLock.lock()
            streaming = false
            inputContinuation = nil
            streamConverter = nil
            streamedFrames = 0
            sessionLock.unlock()
            continuation.finish()
            Latency.note("apple streaming start failed, falling back to batch: \(error.localizedDescription)")
        }
    }

    /// Caller must hold `sessionLock`. Yielding into an unbounded `AsyncStream` does not call
    /// back into our code, so holding the lock across it is safe and keeps audio ordered.
    private func yieldLocked(
        _ buffer: AVAudioPCMBuffer,
        through converter: StreamingResampler?,
        into continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        let outgoing: AVAudioPCMBuffer
        if let converter {
            guard let converted = converter.convertOwned(buffer) else { return }
            outgoing = converted
        } else {
            outgoing = buffer
        }
        continuation.yield(AnalyzerInput(buffer: outgoing))
    }

    // MARK: - Audio in

    /// Called on the collector's IO queue, roughly four times a second, with an owned buffer.
    func consumeStreamingBuffer(_ buffer: AVAudioPCMBuffer) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        streamedFrames += Int(buffer.frameLength)
        if streaming, let continuation = inputContinuation {
            yieldLocked(buffer, through: streamConverter, into: continuation)
        } else if pendingFrames < Self.maxPendingFrames {
            pendingBuffers.append(buffer)
            pendingFrames += Int(buffer.frameLength)
        } else {
            droppedEarlyAudio = true
        }
    }

    func consumeCapture(_ capture: AudioCaptureSnapshot) {
        sessionLock.lock()
        self.capture = capture
        sessionLock.unlock()
    }

    func consumeFile(_ url: URL) {
        sessionLock.lock()
        fileURL = url
        sessionLock.unlock()
    }

    // MARK: - Stop

    func stopStreaming() async throws -> String {
        defer {
            sessionLock.lock()
            let continuation = partialContinuation
            partialContinuation = nil
            sessionLock.unlock()
            continuation?.finish()
            tearDownPreparedWork()
            Task { await Self.prewarm() }
        }

        sessionLock.lock()
        let wasStreaming = streaming
        let continuation = inputContinuation
        let streamedSeconds = Double(streamedFrames) / AudioResampler.targetSampleRate
        // Anything still queued from before the analyzer opened has to go in before the finish.
        if wasStreaming, let continuation {
            for buffered in pendingBuffers {
                yieldLocked(buffered, through: streamConverter, into: continuation)
            }
        }
        pendingBuffers = []
        pendingFrames = 0
        let lostEarlyAudio = droppedEarlyAudio
        inputContinuation = nil
        streaming = false
        let fileURL = self.fileURL
        let capture = self.capture
        self.capture = nil
        self.fileURL = nil
        sessionLock.unlock()

        var text = ""
        if wasStreaming, let continuation {
            continuation.finish()
            text = await finishLiveAnalysis()
        }

        if lostEarlyAudio, !text.isEmpty {
            // Better a slow correct transcript than a fast one missing its opening.
            Latency.note("apple backlog overflowed — re-analysing the recording instead")
            text = ""
        }

        // Streaming covered the take. Nothing else to do.
        if !text.isEmpty {
            Self.streamedFlag.withLock { $0 = true }
            yieldPartial(text)
            return text
        }
        Self.streamedFlag.withLock { $0 = false }

        // Streaming was off, or it produced nothing. Fall back to the recorded audio.
        let ownedURL: URL
        let shouldDelete: Bool
        let samples = capture?.resolvedSamples() ?? []
        if let fileURL {
            ownedURL = fileURL
            shouldDelete = false
        } else if !samples.isEmpty, let wav = try? Self.writeTemporaryWAV(samples) {
            ownedURL = wav
            shouldDelete = true
        } else {
            return text
        }
        defer {
            if shouldDelete {
                try? FileManager.default.removeItem(at: ownedURL)
            }
        }

        let seconds: Double
        if wasStreaming, streamedSeconds > 0 {
            seconds = streamedSeconds
        } else if let file = try? AVAudioFile(forReading: ownedURL) {
            seconds = Double(file.length) / file.fileFormat.sampleRate
        } else if !samples.isEmpty {
            seconds = Double(samples.count) / AudioResampler.targetSampleRate
        } else {
            seconds = 0
        }

        if wasStreaming {
            // The analyzer is finished; only the legacy recognizer is still usable, and only if
            // there was plausibly speech to find.
            guard seconds > 2 else { return "" }
            let legacy = (try? await transcribeFileWithLegacy(ownedURL))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            yieldPartial(legacy)
            return legacy
        }

        let analyzerText = (try? await analyzePreparedFile(ownedURL))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let analyzerWords = analyzerText.split(whereSeparator: \.isWhitespace).count
        let looksThin = analyzerText.isEmpty || (seconds > 12 && analyzerWords < 8)
        if looksThin {
            let legacy = (try? await transcribeFileWithLegacy(ownedURL))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            text = legacy.count >= analyzerText.count ? legacy : analyzerText
        } else {
            text = analyzerText
        }
        yieldPartial(text)
        return text
    }

    private func finishLiveAnalysis() async -> String {
        sessionLock.lock()
        let analyzer = preparedAnalyzer
        let results = resultsTask
        sessionLock.unlock()
        guard let analyzer else { return "" }

        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            Latency.note("apple finalize failed: \(error.localizedDescription)")
            await analyzer.cancelAndFinishNow()
        }
        let transcript = await results?.value ?? AttributedString()
        return String(transcript.characters).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func yieldPartial(_ text: String) {
        guard !text.isEmpty else { return }
        sessionLock.lock()
        let continuation = partialContinuation
        sessionLock.unlock()
        continuation?.yield(text)
    }

    /// Abandon the take without producing a transcript.
    ///
    /// Without this an abandoned take leaves an analyzer mid-`start(inputSequence:)` with an open
    /// continuation and a results task awaiting `transcriber.results` forever, retaining both.
    func cancelStreaming() async {
        sessionLock.lock()
        let continuation = inputContinuation
        let analyzer = preparedAnalyzer
        let partial = partialContinuation
        inputContinuation = nil
        partialContinuation = nil
        streaming = false
        pendingBuffers = []
        pendingFrames = 0
        sessionLock.unlock()

        continuation?.finish()
        partial?.finish()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        tearDownPreparedWork()
    }

    // MARK: - Warm pair

    static func evict() {
        warmLock.lock()
        let analyzer = warmAnalyzer
        warmTranscriber = nil
        warmAnalyzer = nil
        warmFormat = nil
        let task = prewarmTask
        prewarmTask = nil
        prewarmGeneration &+= 1
        warmLock.unlock()
        task?.cancel()
        if let analyzer {
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }
    }

    static func prewarm() async {
        let task: Task<Void, Never>
        let generation: UInt64
        warmLock.lock()
        if let existing = prewarmTask {
            task = existing
            warmLock.unlock()
            await task.value
            return
        }
        prewarmGeneration &+= 1
        generation = prewarmGeneration
        task = Task {
            await runPrewarm()
        }
        prewarmTask = task
        warmLock.unlock()
        await task.value
        warmLock.lock()
        if prewarmGeneration == generation {
            prewarmTask = nil
        }
        warmLock.unlock()
    }

    private static func runPrewarm() async {
        _ = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        do {
            let work = try await makePreparedWork(hints: [])
            let previous: SpeechAnalyzer?
            warmLock.lock()
            previous = warmAnalyzer
            warmTranscriber = work.transcriber
            warmAnalyzer = work.analyzer
            warmFormat = work.format
            warmLock.unlock()
            if let previous {
                await previous.cancelAndFinishNow()
            }
            await reserveLocaleIfNeeded()
        } catch {}
    }

    /// Reserving the locale stops the OS purging the on-device assets under disk pressure,
    /// which is the other way a long-idle Echo ends up reloading a model on the hot path.
    private static func reserveLocaleIfNeeded() async {
        cacheLock.lock()
        let already = reservedLocale
        let locale = cachedLocale
        cacheLock.unlock()
        guard already == nil, let locale else { return }
        guard (try? await AssetInventory.reserve(locale: locale)) == true else { return }
        cacheLock.lock()
        reservedLocale = locale
        cacheLock.unlock()
    }

    private func prepareAnalyzerWork() async throws {
        sessionLock.lock()
        let alreadyPrepared = preparedAnalyzer != nil
        sessionLock.unlock()
        if alreadyPrepared { return }

        Self.warmLock.lock()
        let warmT = Self.warmTranscriber
        let warmA = Self.warmAnalyzer
        let warmF = Self.warmFormat
        Self.warmTranscriber = nil
        Self.warmAnalyzer = nil
        Self.warmFormat = nil
        Self.warmLock.unlock()

        if let warmT, let warmA {
            sessionLock.lock()
            preparedTranscriber = warmT
            preparedAnalyzer = warmA
            analyzerFormat = warmF
            sessionLock.unlock()
            await applyVocabulary(to: warmA)
            startResultsTask(warmT)
            return
        }

        sessionLock.lock()
        let hints = vocabularyHints
        sessionLock.unlock()
        let work = try await Self.makePreparedWork(hints: hints)
        sessionLock.lock()
        preparedTranscriber = work.transcriber
        preparedAnalyzer = work.analyzer
        analyzerFormat = work.format
        sessionLock.unlock()
        startResultsTask(work.transcriber)
    }

    private func startResultsTask(_ transcriber: SpeechTranscriber) {
        sessionLock.lock()
        resultsTask?.cancel()
        resultsTask = Task {
            var transcript = AttributedString()
            do {
                for try await result in transcriber.results {
                    transcript.append(result.text)
                }
            } catch {}
            return transcript
        }
        sessionLock.unlock()
    }

    private func tearDownPreparedWork() {
        sessionLock.lock()
        resultsTask?.cancel()
        resultsTask = nil
        preparedTranscriber = nil
        preparedAnalyzer = nil
        analyzerFormat = nil
        inputContinuation = nil
        streamConverter = nil
        streaming = false
        streamedFrames = 0
        pendingBuffers = []
        pendingFrames = 0
        droppedEarlyAudio = false
        analyzing = false
        sessionLock.unlock()
    }

    /// Whether a format is exactly what the capture pipeline already produces.
    private static func matchesCaptureFormat(_ format: AVAudioFormat) -> Bool {
        let capture = AudioResampler.mono16kFormat()
        return format.sampleRate == capture.sampleRate
            && format.channelCount == capture.channelCount
            && format.commonFormat == capture.commonFormat
            && format.isInterleaved == capture.isInterleaved
    }

    private static func makePreparedWork(
        hints: [String]
    ) async throws -> (transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer, format: AVAudioFormat?) {
        guard let locale = await resolvedLocale() else {
            throw TranscriptionError.recognizerUnavailable
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await ensureAssets(for: transcriber)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: analyzerOptions)
        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(hints.prefix(100))
            try? await analyzer.setContext(context)
        }
        // Ask the analyzer what it wants rather than assuming.
        //
        // `prepareToAnalyze(in:)` happily accepts 16 kHz mono Float32 — the format the capture
        // pipeline produces — and then the framework aborts the process the moment such a buffer
        // is streamed in, with "Failed precondition: Audio sample data must be 16-bit signed
        // integers". The old code never hit this because it handed over a file and let the
        // framework do its own conversion. Streaming has to convert on the way in.
        let preferred = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let target = preferred ?? AudioResampler.mono16kFormat()
        var resolvedFormat: AVAudioFormat? = target
        do {
            try await analyzer.prepareToAnalyze(in: target)
        } catch {
            // Last resort: let the analyzer pick for itself and convert to whatever it reports.
            try await analyzer.prepareToAnalyze(in: nil)
            resolvedFormat = preferred
        }
        return (transcriber, analyzer, resolvedFormat)
    }

    private func applyVocabulary(to analyzer: SpeechAnalyzer) async {
        sessionLock.lock()
        let hints = vocabularyHints
        let busy = analyzing || streaming
        sessionLock.unlock()
        guard !busy, !hints.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = Array(hints.prefix(100))
        try? await analyzer.setContext(context)
    }

    private static func resolvedLocale() async -> Locale? {
        cacheLock.lock()
        let cached = cachedLocale
        cacheLock.unlock()
        if let cached { return cached }

        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if locale == nil {
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        }
        cacheLock.lock()
        cachedLocale = locale
        cacheLock.unlock()
        return locale
    }

    private static func ensureAssets(for transcriber: SpeechTranscriber) async throws {
        cacheLock.lock()
        let ready = assetsReady
        cacheLock.unlock()
        if ready { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        cacheLock.lock()
        assetsReady = true
        cacheLock.unlock()
    }

    // MARK: - Batch fallback

    private func analyzePreparedFile(_ url: URL) async throws -> String {
        sessionLock.lock()
        let hasAnalyzer = preparedAnalyzer != nil
        sessionLock.unlock()
        if !hasAnalyzer {
            try await prepareAnalyzerWork()
        }
        sessionLock.lock()
        let analyzer = preparedAnalyzer
        sessionLock.unlock()
        guard let analyzer else {
            throw TranscriptionError.recognizerUnavailable
        }

        await applyVocabulary(to: analyzer)

        sessionLock.lock()
        analyzing = true
        sessionLock.unlock()
        defer {
            sessionLock.lock()
            analyzing = false
            sessionLock.unlock()
        }

        let analysisURL = try Self.fileAlignedToAnalyzer(url)
        defer {
            if analysisURL != url {
                try? FileManager.default.removeItem(at: analysisURL)
            }
        }
        let file = try AVAudioFile(forReading: analysisURL)
        do {
            let lastTime = try await analyzer.analyzeSequence(from: file)
            if let lastTime {
                try await analyzer.finalizeAndFinish(through: lastTime)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
        } catch {
            sessionLock.lock()
            resultsTask?.cancel()
            sessionLock.unlock()
            await analyzer.cancelAndFinishNow()
            throw error
        }

        sessionLock.lock()
        let results = resultsTask
        sessionLock.unlock()
        let transcript = await results?.value ?? AttributedString()
        return String(transcript.characters)
    }

    // MARK: - Legacy file recognizer

    /// Last resort only. Capped tight: it used to be able to add 2.5 s to a take that had
    /// already been transcribed.
    private func transcribeFileWithLegacy(_ url: URL, timeout: Double = 1.5) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current)
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.taskHint = .dictation
        sessionLock.lock()
        let hints = vocabularyHints
        sessionLock.unlock()
        if !hints.isEmpty {
            request.contextualStrings = Array(hints.prefix(100))
        }
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()

            let deadline = DispatchWorkItem {
                gate.resume(continuation)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

            recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    gate.storeBest(result.bestTranscription.formattedString)
                    if result.isFinal {
                        deadline.cancel()
                        gate.resume(continuation)
                    }
                } else if error != nil {
                    deadline.cancel()
                    gate.resume(continuation)
                }
            }
        }
    }

    private static func fileAlignedToAnalyzer(_ url: URL) throws -> URL {
        let file = try AVAudioFile(forReading: url)
        let written = AudioResampler.mono16kFormat()
        let format = file.processingFormat
        if format.sampleRate == written.sampleRate,
           format.channelCount == 1,
           format.commonFormat == .pcmFormatFloat32 {
            return url
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { return url }
        try file.read(into: buffer)
        guard let converted = AudioResampler.convertToMono16k(buffer) else { return url }
        let aligned = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-\(UUID().uuidString).caf")
        do {
            let writer = try AVAudioFile(
                forWriting: aligned,
                settings: written.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try writer.write(from: converted)
        } catch {
            try? FileManager.default.removeItem(at: aligned)
            throw error
        }
        return aligned
    }

    private static func writeTemporaryWAV(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-\(UUID().uuidString).wav")
        try AudioResampler.wavData(from: samples).write(to: url)
        return url
    }
}

/// Timeout and the recognition callback must not both resume the continuation.
/// `latest` is shared across the Speech callback and the timeout work item.
nonisolated private final class ResumeGate: @unchecked Sendable {
    private struct State {
        var settled = false
        var latest = ""
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func storeBest(_ text: String) {
        state.withLock {
            if text.count >= $0.latest.count {
                $0.latest = text
            }
        }
    }

    func resume(_ continuation: CheckedContinuation<String, Error>) {
        state.withLock {
            guard !$0.settled else { return }
            $0.settled = true
            continuation.resume(returning: $0.latest)
        }
    }
}
