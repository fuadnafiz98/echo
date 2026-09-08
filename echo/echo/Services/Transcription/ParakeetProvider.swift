import AVFoundation
import FluidAudio
import os

nonisolated final class ParakeetProvider: TranscriptionProvider, BatchAudioConsumer, @unchecked Sendable {
    private let variant: ParakeetVariant
    private var samples: [Float] = []
    private var partialContinuation: AsyncStream<String>.Continuation?

    private struct CachedManager: Sendable {
        var variant: String
        var manager: AsrManager
        var folderPath: String
        var decoderLayers: Int
    }

    private struct InflightLoad: Sendable {
        let generation: UInt64
        let task: Task<CachedManager, Error>
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: CachedManager?
    nonisolated(unsafe) private static var inflight: [String: InflightLoad] = [:]
    nonisolated(unsafe) private static var inflightGeneration: UInt64 = 0
    nonisolated(unsafe) private static var warmTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "echo", category: "parakeet")

    init(variant: ParakeetVariant) {
        self.variant = variant
    }

    var partialTranscript: AsyncStream<String> {
        AsyncStream { [weak self] continuation in
            self?.partialContinuation = continuation
        }
    }

    static func evict(variant: ParakeetVariant? = nil) {
        cacheLock.lock()
        let warm = warmTask
        warmTask = nil
        let cancelled: [Task<CachedManager, Error>]
        if let variant {
            if cached?.variant == variant.rawValue {
                cached = nil
            }
            var remaining: [String: InflightLoad] = [:]
            var toCancel: [Task<CachedManager, Error>] = []
            for (key, load) in inflight {
                if key.hasPrefix(variant.rawValue + "\n") {
                    toCancel.append(load.task)
                } else {
                    remaining[key] = load
                }
            }
            inflight = remaining
            cancelled = toCancel
        } else {
            cancelled = inflight.values.map(\.task)
            cached = nil
            inflight.removeAll()
        }
        cacheLock.unlock()
        warm?.cancel()
        for task in cancelled {
            task.cancel()
        }
    }

    static func prewarm(variant: ParakeetVariant) async {
        guard let folder = LocalModelPresence.folder(for: .parakeet(variant)) else { return }
        guard let loaded = try? await loadCached(variant: variant, folder: folder) else { return }
        await waitForWarm(loaded)
    }

    func startStreaming() async throws {
        samples = []
        guard let folder = LocalModelPresence.folder(for: .parakeet(variant)) else {
            throw TranscriptionError.modelNotDownloaded
        }
        let loaded = try await Self.loadCached(variant: variant, folder: folder)
        await Self.waitForWarm(loaded)
    }

    func consumeSamples(_ samples: [Float]) {
        self.samples = samples
    }

    func stopStreaming() async throws -> String {
        defer {
            partialContinuation?.finish()
            partialContinuation = nil
        }

        guard !samples.isEmpty else { return "" }

        let loaded = try await Self.loadCached(variant: variant, folder: try Self.requiredFolder(variant))
        var decoderState = TdtDecoderState.make(decoderLayers: loaded.decoderLayers)
        let result = try await loaded.manager.transcribe(samples, decoderState: &decoderState)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            partialContinuation?.yield(text)
        }
        return text
    }

    private static func requiredFolder(_ variant: ParakeetVariant) throws -> URL {
        guard let folder = LocalModelPresence.folder(for: .parakeet(variant)) else {
            throw TranscriptionError.modelNotDownloaded
        }
        return folder
    }

    private static func cacheKey(variant: ParakeetVariant, folder: URL) -> String {
        variant.rawValue + "\n" + folder.standardizedFileURL.path
    }

    private static func loadCached(variant: ParakeetVariant, folder: URL) async throws -> CachedManager {
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
        log.debug("Parakeet cache miss, loading \(variant.rawValue, privacy: .public)")
        #endif

        inflightGeneration &+= 1
        let generation = inflightGeneration
        let task = Task<CachedManager, Error> {
            let version: AsrModelVersion = variant == .v2English ? .v2 : .v3
            guard AsrModels.modelsExist(at: folder, version: version) else {
                LocalModelPresence.remove(.parakeet(variant))
                throw TranscriptionError.modelNotDownloaded
            }
            let models = try await AsrModels.load(from: folder, version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            let layers = await manager.decoderLayerCount
            return CachedManager(
                variant: variant.rawValue,
                manager: manager,
                folderPath: path,
                decoderLayers: layers
            )
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
            cached = loaded
            inflight[key] = nil
            if warmTask == nil {
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

    private static func makeWarmTask(_ loaded: CachedManager) -> Task<Void, Never> {
        let manager = loaded.manager
        let layers = loaded.decoderLayers
        return Task.detached(priority: .utility) {
            var decoderState = TdtDecoderState.make(decoderLayers: layers)
            // Same 15 s pad as a real take — compiles ANE while the user is still talking / at launch.
            let warmup = [Float](repeating: 0.0001, count: 4_800)
            _ = try? await manager.transcribe(warmup, decoderState: &decoderState)
        }
    }

    private static func waitForWarm(_ loaded: CachedManager) async {
        cacheLock.lock()
        if warmTask == nil {
            warmTask = makeWarmTask(loaded)
        }
        let warm = warmTask
        cacheLock.unlock()
        await warm?.value
    }
}
