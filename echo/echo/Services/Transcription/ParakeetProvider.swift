import AVFoundation
import FluidAudio
import os

/// NVIDIA Parakeet TDT via FluidAudio, in one of two pipelines.
///
/// - ``TranscriptionPipeline/standard`` hands the whole take to FluidAudio at stop. Its own
///   chunking resets the decoder for every ~15 s chunk and stitches by timestamp. Cost at stop is
///   ~110 ms plus ~7 ms per second of audio: fine for a sentence, seconds for a long dictation.
/// - ``TranscriptionPipeline/streaming`` feeds ``PauseWindowPipeline`` while the user talks. It
///   never threads one decoder state across windows — each window is decoded fresh, exactly like
///   FluidAudio's chunks, just cut at real pauses instead of fixed offsets — so stop only has the
///   tail since the last pause, and usually not even that.
///
/// Either way the whole take stays available, and any streaming failure falls back to it.
nonisolated final class ParakeetProvider: TranscriptionProvider, BatchAudioConsumer, StreamingAudioConsumer,
                                          StopAnticipating, @unchecked Sendable {
    private let variant: ParakeetVariant
    private let pipelineMode: TranscriptionPipeline
    private let layout: PauseWindowPipeline.Layout
    private let sessionLock = NSLock()
    private var capture: AudioCaptureSnapshot?
    private var partialContinuation: AsyncStream<String>.Continuation?
    /// Non-nil only for a streaming take, between `startStreaming` and stop or cancel.
    private var pipeline: PauseWindowPipeline?
    private var streamingStats: PauseWindowPipeline.Stats?

    /// What the last streaming stop had left to do. Benchmarks read it.
    var lastStreamingStats: PauseWindowPipeline.Stats? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return streamingStats
    }

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

    init(
        variant: ParakeetVariant,
        pipeline: TranscriptionPipeline = .current,
        layout: PauseWindowPipeline.Layout = .standard
    ) {
        self.variant = variant
        pipelineMode = pipeline
        self.layout = layout
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
        let managerToClean: AsrManager?
        let cancelled: [Task<CachedManager, Error>]
        if let variant {
            if cached?.variant == variant.rawValue {
                managerToClean = cached?.manager
                cached = nil
            } else {
                managerToClean = nil
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
            managerToClean = cached?.manager
            cached = nil
            inflight.removeAll()
        }
        cacheLock.unlock()
        warm?.cancel()
        for task in cancelled {
            task.cancel()
        }
        if let managerToClean {
            Task {
                await managerToClean.cleanup()
            }
        }
    }

    /// Whether a take could start on this variant without loading it. A cold take gets an Apple
    /// Speech shadow so stop never waits out the load.
    static func isResident(variant: ParakeetVariant) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cached?.variant == variant.rawValue
    }

    /// Benchmarks only: the resident manager, loading it first if needed.
    static func managerForBenchmark(variant: ParakeetVariant) async throws -> (AsrManager, Int) {
        let loaded = try await loadCached(variant: variant, folder: try requiredFolder(variant))
        await waitForWarm(loaded)
        return (loaded.manager, loaded.decoderLayers)
    }

    static func prewarm(variant: ParakeetVariant) async {
        guard let folder = LocalModelPresence.folder(for: .parakeet(variant)) else { return }
        guard let loaded = try? await loadCached(variant: variant, folder: folder) else { return }
        await waitForWarm(loaded)
    }

    func startStreaming() async throws {
        sessionLock.lock()
        capture = nil
        sessionLock.unlock()

        guard let folder = LocalModelPresence.folder(for: .parakeet(variant)) else {
            throw TranscriptionError.modelNotDownloaded
        }

        // Installed *before* the load is awaited: the microphone is already running, and a cold
        // load can take tens of seconds. Windows queue behind the load instead of being lost.
        if pipelineMode == .streaming {
            let variant = variant
            let pipeline = PauseWindowPipeline(layout: layout) { samples in
                let loaded = try await Self.loadCached(variant: variant, folder: folder)
                return try await Self.decodeWindow(samples, with: loaded)
            }
            sessionLock.lock()
            self.pipeline = pipeline
            sessionLock.unlock()
        }

        let loaded = try await Self.loadCached(variant: variant, folder: folder)
        await Self.waitForWarm(loaded)
    }

    var wantsStreamingBuffers: Bool { pipelineMode == .streaming }

    /// Collector IO queue, ~256 ms of 16 kHz mono per call.
    func consumeStreamingBuffer(_ buffer: AVAudioPCMBuffer) {
        sessionLock.lock()
        let pipeline = self.pipeline
        sessionLock.unlock()
        pipeline?.append(AudioResampler.floats(from: buffer))
    }

    func anticipateStop() {
        sessionLock.lock()
        let pipeline = self.pipeline
        sessionLock.unlock()
        pipeline?.anticipateStop()
    }

    func consumeCapture(_ capture: AudioCaptureSnapshot) {
        sessionLock.lock()
        self.capture = capture
        sessionLock.unlock()
    }

    func cancelStreaming() async {
        sessionLock.lock()
        let pipeline = self.pipeline
        self.pipeline = nil
        sessionLock.unlock()
        pipeline?.cancel()
    }

    func stopStreaming() async throws -> String {
        defer {
            partialContinuation?.finish()
            partialContinuation = nil
        }

        sessionLock.lock()
        let capture = self.capture
        self.capture = nil
        let pipeline = self.pipeline
        self.pipeline = nil
        sessionLock.unlock()

        if let pipeline {
            let text = await Self.finishStreaming(pipeline, capturedFrames: capture?.capturedFrames ?? 0)
            sessionLock.lock()
            streamingStats = pipeline.stats
            sessionLock.unlock()
            if let text {
                if !text.isEmpty {
                    partialContinuation?.yield(text)
                }
                #if ECHO_STREAM_COMPARE
                if StreamingComparison.isEnabled, let capture {
                    let variant = variant
                    StreamingComparison.record(
                        samples: capture.resolvedSamples(),
                        streamed: text,
                        stats: pipeline.stats
                    ) { audio in
                        let loaded = try await Self.loadCached(variant: variant, folder: try Self.requiredFolder(variant))
                        var decoderState = TdtDecoderState.make(decoderLayers: loaded.decoderLayers)
                        let result = try await loaded.manager.transcribe(audio, decoderState: &decoderState)
                        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                #endif
                return text
            }
        }

        let audio = capture?.resolvedSamples() ?? []
        guard !audio.isEmpty else { return "" }

        let loaded = try await Self.loadCached(variant: variant, folder: try Self.requiredFolder(variant))
        var decoderState = TdtDecoderState.make(decoderLayers: loaded.decoderLayers)
        let result = try await loaded.manager.transcribe(audio, decoderState: &decoderState)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            partialContinuation?.yield(text)
        }
        return text
    }

    /// `nil` means the streamed transcript cannot be trusted and the whole take must be decoded.
    private static func finishStreaming(_ pipeline: PauseWindowPipeline, capturedFrames: Int) async -> String? {
        guard pipeline.frameCount > 0, pipeline.sawAtLeast(frames: capturedFrames) else {
            pipeline.cancel()
            Latency.note("parakeet streaming saw \(pipeline.frameCount) of \(capturedFrames) frames — retranscribing the whole take")
            return nil
        }
        do {
            let text = try await pipeline.finish()
            if let stats = pipeline.stats {
                Latency.streamingTail(
                    tailSeconds: stats.tailSeconds,
                    speculativeHit: stats.speculativeHit,
                    reused: stats.reusedSpeculation,
                    cuts: stats.cuts,
                    forcedCuts: stats.forcedCuts,
                    speculations: stats.speculations,
                    anticipated: stats.anticipated,
                    path: stats.stopPath
                )
            }
            return text
        } catch {
            Latency.note("parakeet streaming failed — retranscribing the whole take")
            return nil
        }
    }

    /// One pipeline window, decoded with a fresh decoder state like each of FluidAudio's chunks.
    private static func decodeWindow(_ samples: [Float], with loaded: CachedManager) async throws -> [TimedToken] {
        var decoderState = TdtDecoderState.make(decoderLayers: loaded.decoderLayers)
        let result = try await loaded.manager.transcribe(samples, decoderState: &decoderState)
        let timings = result.tokenTimings ?? []
        // Text without timings cannot be placed on the take's clock; let the take fall back.
        if timings.isEmpty, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ChunkPipelineFailure()
        }
        return timings.map { TimedToken(text: $0.token, start: $0.startTime) }
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
            let loadStart = CFAbsoluteTimeGetCurrent()
            let version: AsrModelVersion = variant == .v2English ? .v2 : .v3
            guard AsrModels.modelsExist(at: folder, version: version) else {
                LocalModelPresence.remove(.parakeet(variant))
                throw TranscriptionError.modelNotDownloaded
            }
            let models = try await AsrModels.load(from: folder, version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            let layers = await manager.decoderLayerCount
            Latency.modelLoad("parakeet.\(variant.rawValue)", Latency.milliseconds(since: loadStart))
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
            let previous = cached
            cached = loaded
            inflight[key] = nil
            if warmTask == nil {
                warmTask = makeWarmTask(loaded)
            }
            let stale = previous.flatMap { old in
                old.variant == variant.rawValue && old.folderPath == path ? nil : old.manager
            }
            cacheLock.unlock()
            if let stale {
                Task { await stale.cleanup() }
            }
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
        let name = "parakeet.\(loaded.variant)"
        return Task.detached(priority: .utility) {
            let warmStart = CFAbsoluteTimeGetCurrent()
            var decoderState = TdtDecoderState.make(decoderLayers: layers)
            // Same 15 s pad as a real take — compiles ANE while the user is still talking / at launch.
            let warmup = [Float](repeating: 0.0001, count: 4_800)
            _ = try? await manager.transcribe(warmup, decoderState: &decoderState)
            Latency.modelWarm(name, Latency.milliseconds(since: warmStart))
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
