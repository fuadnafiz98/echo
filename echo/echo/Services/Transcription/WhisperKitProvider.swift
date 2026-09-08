import AVFoundation
import WhisperKit
import os

nonisolated final class WhisperKitProvider: TranscriptionProvider, BatchAudioConsumer, @unchecked Sendable {
    private let variant: WhisperVariant
    private let session = OSAllocatedUnfairLock(initialState: SessionState())
    private var partialContinuation: AsyncStream<String>.Continuation?

    private struct SessionState: Sendable {
        var samples: [Float] = []
        var vocabularyHints: [String] = []
    }

    private struct CachedKit: @unchecked Sendable {
        var variant: String
        var kit: WhisperKit
        var folderPath: String
    }

    private struct InflightLoad: Sendable {
        let generation: UInt64
        let task: Task<CachedKit, Error>
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: CachedKit?
    nonisolated(unsafe) private static var inflight: [String: InflightLoad] = [:]
    nonisolated(unsafe) private static var inflightGeneration: UInt64 = 0
    nonisolated(unsafe) private static var warmTask: Task<Void, Never>?
    nonisolated(unsafe) private static var promptCache: (variant: String, key: String, tokens: [Int])?

    private static let log = Logger(subsystem: "echo", category: "latency")
    private static let windowSamples = 480_000

    init(variant: WhisperVariant) {
        self.variant = variant
    }

    var partialTranscript: AsyncStream<String> {
        AsyncStream { [weak self] continuation in
            self?.partialContinuation = continuation
        }
    }

    func setVocabularyHints(_ hints: [String]) {
        let clipped = Array(hints.prefix(60))
        session.withLock { $0.vocabularyHints = clipped }
        encodePromptIfKitReady(clipped)
    }

    static func evict(variant: WhisperVariant? = nil) {
        cacheLock.lock()
        let warm = warmTask
        warmTask = nil
        let cancelled: [Task<CachedKit, Error>]
        if let variant {
            if cached?.variant == variant.rawValue {
                cached = nil
            }
            var remaining: [String: InflightLoad] = [:]
            var toCancel: [Task<CachedKit, Error>] = []
            for (key, load) in inflight {
                if key.hasPrefix(variant.rawValue + "\n") {
                    toCancel.append(load.task)
                } else {
                    remaining[key] = load
                }
            }
            inflight = remaining
            cancelled = toCancel
            if promptCache?.variant == variant.rawValue {
                promptCache = nil
            }
        } else {
            cancelled = inflight.values.map(\.task)
            cached = nil
            inflight.removeAll()
            promptCache = nil
        }
        cacheLock.unlock()
        warm?.cancel()
        for task in cancelled {
            task.cancel()
        }
    }

    static func prewarm(variant: WhisperVariant) async {
        guard let folder = LocalModelPresence.folder(for: .whisper(variant)) else { return }
        guard let loaded = try? await loadCached(variant: variant, folder: folder) else { return }
        await waitForWarm(loaded)
    }

    func startStreaming() async throws {
        let hints = session.withLock {
            $0.samples = []
            return $0.vocabularyHints
        }

        guard let folder = LocalModelPresence.folder(for: .whisper(variant)) else {
            throw TranscriptionError.modelNotDownloaded
        }
        let loaded = try await Self.loadCached(variant: variant, folder: folder)
        await Self.waitForWarm(loaded)
        encodePromptIfKitReady(hints)
    }

    func consumeSamples(_ samples: [Float]) {
        session.withLock { $0.samples = samples }
    }

    func stopStreaming() async throws -> String {
        defer {
            partialContinuation?.finish()
            partialContinuation = nil
        }

        let (audio, hints) = session.withLock { ($0.samples, $0.vocabularyHints) }
        guard !audio.isEmpty else { return "" }

        let loaded = try await Self.loadCached(variant: variant, folder: try Self.requiredFolder(variant))
        await Self.awaitWarmIfRunning()

        let promptTokens = Self.cachedPromptTokens(variant: variant, hints: hints)
        let options = Self.hotPathOptions(promptTokens: promptTokens, sampleCount: audio.count)

        #if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
        #endif
        let results = try await loaded.kit.transcribe(audioArray: audio, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        Self.log.debug(
            "whisper decode \(ms, format: .fixed(precision: 1))ms samples=\(audio.count) promptTokens=\(promptTokens?.count ?? 0)"
        )
        #endif

        if !text.isEmpty {
            partialContinuation?.yield(text)
        }
        return text
    }

    private static func requiredFolder(_ variant: WhisperVariant) throws -> URL {
        guard let folder = LocalModelPresence.folder(for: .whisper(variant)) else {
            throw TranscriptionError.modelNotDownloaded
        }
        return folder
    }

    private static func cacheKey(variant: WhisperVariant, folder: URL) -> String {
        variant.rawValue + "\n" + folder.standardizedFileURL.path
    }

    private static func loadCached(variant: WhisperVariant, folder: URL) async throws -> CachedKit {
        let key = cacheKey(variant: variant, folder: folder)
        let path = folder.standardizedFileURL.path

        cacheLock.lock()
        if let cached, cached.variant == variant.rawValue, cached.folderPath == path {
            let hit = cached
            cacheLock.unlock()
            return hit
        }
        if let existing = inflight[key] {
            let task = existing.task
            cacheLock.unlock()
            return try await task.value
        }

        #if DEBUG
        log.debug("whisper cache miss, loading \(variant.rawValue, privacy: .public)")
        #endif

        inflightGeneration &+= 1
        let generation = inflightGeneration
        let task = Task<CachedKit, Error> {
            let downloadBase = LocalModelPaths.whisperDirectory()
            guard LocalModelPaths.whisperTokenizerPresent(
                modelFolder: folder,
                downloadBase: downloadBase,
                tokenizerRepository: variant.tokenizerRepository
            ) else {
                throw TranscriptionError.modelNotDownloaded
            }
            let config = WhisperKitConfig(
                model: variant.rawValue,
                downloadBase: downloadBase,
                modelFolder: folder.path,
                tokenizerFolder: downloadBase,
                verbose: false,
                prewarm: false,
                load: true,
                download: false
            )
            let kit = try await WhisperKit(config)
            return CachedKit(variant: variant.rawValue, kit: kit, folderPath: path)
        }
        inflight[key] = InflightLoad(generation: generation, task: task)
        cacheLock.unlock()

        do {
            let loaded = try await task.value
            cacheLock.lock()
            guard inflight[key]?.generation == generation else {
                cacheLock.unlock()
                return loaded
            }
            let same = cached?.variant == variant.rawValue && cached?.folderPath == path
            cached = loaded
            inflight[key] = nil
            if !same || warmTask == nil {
                warmTask?.cancel()
                warmTask = makeWarmTask(loaded)
            }
            cacheLock.unlock()
            return loaded
        } catch {
            cacheLock.lock()
            if inflight[key]?.generation == generation {
                inflight[key] = nil
            }
            cacheLock.unlock()
            throw error
        }
    }

    private static func makeWarmTask(_ loaded: CachedKit) -> Task<Void, Never> {
        let kit = loaded.kit
        return Task.detached(priority: .utility) {
            let options = hotPathOptions(promptTokens: nil, sampleCount: 16_000)
            let warmup = [Float](repeating: 0.0001, count: 16_000)
            _ = try? await kit.transcribe(audioArray: warmup, decodeOptions: options)
        }
    }

    private static func waitForWarm(_ loaded: CachedKit) async {
        cacheLock.lock()
        if warmTask == nil {
            warmTask = makeWarmTask(loaded)
        }
        let warm = warmTask
        cacheLock.unlock()
        await warm?.value
    }

    private static func awaitWarmIfRunning() async {
        cacheLock.lock()
        let warm = warmTask
        cacheLock.unlock()
        await warm?.value
    }

    private static func hotPathOptions(promptTokens: [Int]?, sampleCount: Int) -> DecodingOptions {
        DecodingOptions(
            language: "en",
            temperature: 0,
            temperatureFallbackCount: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: sampleCount <= windowSamples,
            promptTokens: promptTokens,
            concurrentWorkerCount: 1
        )
    }

    private func encodePromptIfKitReady(_ hints: [String]) {
        guard !hints.isEmpty else { return }
        let key = Self.promptKey(hints)
        if Self.cachedPromptTokens(variant: variant, hints: hints) != nil {
            return
        }

        Self.cacheLock.lock()
        let kit = Self.cached?.kit
        let hit = Self.cached?.variant == variant.rawValue
        Self.cacheLock.unlock()
        guard hit, let kit, let tokens = Self.encodePrompt(hints, kit: kit) else { return }
        Self.storePrompt(variant: variant, key: key, tokens: tokens)
    }

    private static func promptKey(_ hints: [String]) -> String {
        hints.prefix(60).joined(separator: "\u{1e}")
    }

    private static func cachedPromptTokens(variant: WhisperVariant, hints: [String]) -> [Int]? {
        guard !hints.isEmpty else { return nil }
        let key = promptKey(hints)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let promptCache, promptCache.variant == variant.rawValue, promptCache.key == key else {
            return nil
        }
        return promptCache.tokens
    }

    private static func storePrompt(variant: WhisperVariant, key: String, tokens: [Int]) {
        cacheLock.lock()
        promptCache = (variant.rawValue, key, tokens)
        cacheLock.unlock()
    }

    private static func encodePrompt(_ hints: [String], kit: WhisperKit) -> [Int]? {
        guard let tokenizer = kit.tokenizer else { return nil }
        let prompt = "Glossary: " + hints.prefix(60).joined(separator: ", ")
        let tokens = tokenizer.encode(text: prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return tokens.isEmpty ? nil : tokens
    }
}
