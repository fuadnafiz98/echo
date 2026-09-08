import AVFoundation
import os
import Speech

/// Records nothing live. Prepares SpeechAnalyzer during listen; stop only analyzes.
nonisolated final class AppleSTTProvider: TranscriptionProvider, BatchAudioConsumer, FileAudioConsumer, @unchecked Sendable {
    private let sessionLock = NSLock()
    private var samples: [Float] = []
    private var fileURL: URL?
    private var vocabularyHints: [String] = []
    private var partialContinuation: AsyncStream<String>.Continuation?
    private var analyzing = false

    private var preparedTranscriber: SpeechTranscriber?
    private var preparedAnalyzer: SpeechAnalyzer?
    private var resultsTask: Task<AttributedString, Never>?

    private static let cacheLock = NSLock()
    private static var cachedLocale: Locale?
    private static var cachedFormat: AVAudioFormat?
    private static var assetsReady = false

    private static let warmLock = NSLock()
    private static var warmTranscriber: SpeechTranscriber?
    private static var warmAnalyzer: SpeechAnalyzer?
    private static var prewarmTask: Task<Void, Never>?
    private static var prewarmGeneration: UInt64 = 0

    func setVocabularyHints(_ hints: [String]) {
        sessionLock.lock()
        vocabularyHints = hints
        sessionLock.unlock()
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
        sessionLock.lock()
        samples = []
        fileURL = nil
        analyzing = false
        sessionLock.unlock()
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
    }

    func consumeSamples(_ samples: [Float]) {
        sessionLock.lock()
        self.samples = samples
        sessionLock.unlock()
    }

    func consumeFile(_ url: URL) {
        sessionLock.lock()
        fileURL = url
        sessionLock.unlock()
    }

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
        let fileURL = self.fileURL
        let samples = self.samples
        sessionLock.unlock()

        let ownedURL: URL
        let shouldDelete: Bool
        if let fileURL {
            ownedURL = fileURL
            shouldDelete = false
        } else if !samples.isEmpty, let wav = try? Self.writeTemporaryWAV(samples) {
            ownedURL = wav
            shouldDelete = true
        } else {
            return ""
        }
        defer {
            if shouldDelete {
                try? FileManager.default.removeItem(at: ownedURL)
            }
        }

        let seconds: Double
        if let file = try? AVAudioFile(forReading: ownedURL) {
            seconds = Double(file.length) / file.fileFormat.sampleRate
        } else if !samples.isEmpty {
            seconds = Double(samples.count) / AudioResampler.targetSampleRate
        } else {
            seconds = 0
        }

        let analyzerText = (try? await analyzePreparedFile(ownedURL))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let analyzerWords = analyzerText.split(whereSeparator: \.isWhitespace).count
        let looksThin = analyzerText.isEmpty || (seconds > 12 && analyzerWords < 8)
        let text: String
        if looksThin {
            let legacy = (try? await transcribeFileWithLegacy(ownedURL, duration: seconds))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            text = legacy.count >= analyzerText.count ? legacy : analyzerText
        } else {
            text = analyzerText
        }

        if !text.isEmpty {
            sessionLock.lock()
            let continuation = partialContinuation
            sessionLock.unlock()
            continuation?.yield(text)
        }
        return text
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
            warmLock.unlock()
            if let previous {
                await previous.cancelAndFinishNow()
            }
        } catch {}
    }

    private func prepareAnalyzerWork() async throws {
        sessionLock.lock()
        let alreadyPrepared = preparedAnalyzer != nil
        sessionLock.unlock()
        if alreadyPrepared { return }

        Self.warmLock.lock()
        let warmT = Self.warmTranscriber
        let warmA = Self.warmAnalyzer
        Self.warmTranscriber = nil
        Self.warmAnalyzer = nil
        Self.warmLock.unlock()

        if let warmT, let warmA {
            sessionLock.lock()
            preparedTranscriber = warmT
            preparedAnalyzer = warmA
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
        analyzing = false
        sessionLock.unlock()
    }

    private static func makePreparedWork(hints: [String]) async throws -> (transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer) {
        guard let locale = await resolvedLocale() else {
            throw TranscriptionError.recognizerUnavailable
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await ensureAssets(for: transcriber)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(hints.prefix(100))
            try? await analyzer.setContext(context)
        }
        let written = AudioResampler.mono16kFormat()
        do {
            try await analyzer.prepareToAnalyze(in: written)
            cacheLock.lock()
            cachedFormat = written
            cacheLock.unlock()
        } catch {
            if let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) {
                try await analyzer.prepareToAnalyze(in: best)
                cacheLock.lock()
                cachedFormat = best
                cacheLock.unlock()
            }
        }
        return (transcriber, analyzer)
    }

    private func applyVocabulary(to analyzer: SpeechAnalyzer) async {
        sessionLock.lock()
        let hints = vocabularyHints
        let busy = analyzing
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

    private func transcribeFileWithLegacy(_ url: URL, duration: Double) async throws -> String {
        _ = duration
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
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        return try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()

            let timeout = DispatchWorkItem {
                gate.resume(continuation)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.5, execute: timeout)

            recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    gate.storeBest(result.bestTranscription.formattedString)
                    if result.isFinal {
                        timeout.cancel()
                        gate.resume(continuation)
                    }
                } else if error != nil {
                    timeout.cancel()
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
