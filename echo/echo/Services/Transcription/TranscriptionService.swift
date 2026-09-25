import AVFoundation

/// Whose text a take is pasted from.
///
/// A take on Whisper or Parakeet that starts while the graph is not loaded also streams into Apple
/// Speech. At stop, if the large graph is still loading, the Apple text is pasted instead of making
/// the user wait out a load that has been measured at 20–40 s after memory pressure.
nonisolated enum StopRoute: Equatable, Sendable {
    case primary
    case fallback

    enum Readiness: Equatable, Sendable {
        case pending
        case ready
        case failed
    }

    /// `nil` means undecided: wait for the next readiness change.
    static func resolve(primary: Readiness, fallback: Readiness?) -> StopRoute? {
        if primary == .ready { return .primary }
        guard let fallback else { return .primary }
        switch fallback {
        case .ready: return .fallback
        case .failed: return .primary
        case .pending: return nil
        }
    }
}

@MainActor
final class TranscriptionService {
    private var activeProvider: (any TranscriptionProvider)?
    private var collector: AudioSampleCollector?
    private var pendingHints: [String] = []

    /// Apple Speech streaming alongside a cold Whisper / Parakeet. Nil when the selected engine
    /// was already resident, or once it became ready mid-take.
    private var fallback: AppleSTTProvider?
    private var primaryReadiness: StopRoute.Readiness = .pending
    private var fallbackReadiness: StopRoute.Readiness?
    private var routeWaiters: [CheckedContinuation<StopRoute, Never>] = []
    /// Set once stop asks for a route. From then on readiness changes only resolve the route;
    /// they no longer tear the fallback down.
    private var finishing = false
    /// Bumped per take so a load that finishes after its take has ended changes nothing.
    private var takeGeneration: UInt64 = 0

    func prepare(
        providerType: TranscriptionProviderType,
        whisperVariant: WhisperVariant,
        parakeetVariant: ParakeetVariant,
        collector: AudioSampleCollector,
        vocabularyHints: [String] = []
    ) async throws {
        takeGeneration &+= 1
        let generation = takeGeneration
        primaryReadiness = .pending
        fallbackReadiness = nil
        fallback = nil
        finishing = false

        self.collector = collector
        let provider = makeProvider(
            for: providerType,
            whisperVariant: whisperVariant,
            parakeetVariant: parakeetVariant
        )
        let hints = vocabularyHints.isEmpty ? pendingHints : vocabularyHints
        if !hints.isEmpty {
            pendingHints = hints
        }
        applyHints(hints, to: provider)
        activeProvider = provider

        if let live = provider as? LiveAudioConsumer {
            collector.setLiveHandler { [weak live] buffer in
                live?.consumeLiveBuffer(buffer)
            }
        }

        // Decided before any audio is routed, so the shadow hears the take from its first word.
        let shadow: AppleSTTProvider? = Self.isCold(
            providerType,
            whisperVariant: whisperVariant,
            parakeetVariant: parakeetVariant
        ) ? AppleSTTProvider() : nil
        if let shadow {
            applyHints(hints, to: shadow)
            fallback = shadow
            fallbackReadiness = .pending
            Latency.note("\(providerType.rawValue) cold at hotkey — shadowing with apple")
        }

        // Hooked *before* `startStreaming`. The microphone is already running by now, and
        // building the analyzer takes a moment; the provider queues whatever arrives in the
        // meantime so the opening words are not lost.
        let streamer = (provider as? StreamingAudioConsumer).flatMap { $0.wantsStreamingBuffers ? $0 : nil }
        if streamer != nil || shadow != nil {
            collector.setDrainedHandler { [weak streamer, weak shadow] buffer in
                streamer?.consumeStreamingBuffer(buffer)
                shadow?.consumeStreamingBuffer(buffer)
            }
        }

        if let shadow {
            startFallback(shadow, generation: generation)
        }

        do {
            try await Task.detached(priority: .userInitiated) {
                try await provider.startStreaming()
            }.value
        } catch {
            markPrimary(.failed, generation: generation)
            throw error
        }
        markPrimary(.ready, generation: generation)
    }

    func setVocabularyHints(_ hints: [String]) {
        pendingHints = hints
        if let provider = activeProvider {
            applyHints(hints, to: provider)
        }
        if let fallback {
            applyHints(hints, to: fallback)
        }
    }

    /// The stop shortcut's modifiers just went down.
    func anticipateStop() {
        guard !finishing, let provider = activeProvider as? StopAnticipating else { return }
        provider.anticipateStop()
    }

    /// Which engine stop should take the transcript from. Returns at once unless the selected
    /// engine and its Apple shadow are both still starting, in which case it waits for whichever
    /// is ready first.
    func stopRoute() async -> StopRoute {
        finishing = true
        if let route = StopRoute.resolve(primary: primaryReadiness, fallback: fallbackReadiness) {
            return route
        }
        return await withCheckedContinuation { continuation in
            routeWaiters.append(continuation)
        }
    }

    func finishAndTranscribe(snapshot: AudioCaptureSnapshot) async throws -> String {
        guard let provider = activeProvider else { return "" }
        collector?.setLiveHandler(nil)
        collector?.setDrainedHandler(nil)
        releaseFallback()

        if let fileConsumer = provider as? FileAudioConsumer, let url = snapshot.fileURL {
            fileConsumer.consumeFile(url)
        }
        let needsRAM = !(provider is AppleSTTProvider) || snapshot.fileURL == nil
        if needsRAM, let batch = provider as? BatchAudioConsumer {
            batch.consumeCapture(snapshot)
        }

        return try await complete(with: provider)
    }

    /// Pastes the Apple shadow's text because the selected engine is still loading.
    ///
    /// The load itself is left running: it fills the engine's static cache, so the next take is
    /// warm. Only this take's claim on the engine is released.
    func finishWithFallback(snapshot: AudioCaptureSnapshot) async throws -> String {
        guard let shadow = fallback else {
            return try await finishAndTranscribe(snapshot: snapshot)
        }
        collector?.setLiveHandler(nil)
        collector?.setDrainedHandler(nil)
        fallback = nil
        fallbackReadiness = nil

        if let primary = activeProvider {
            Task.detached(priority: .utility) {
                await primary.cancelStreaming()
            }
        }

        if let url = snapshot.fileURL {
            shadow.consumeFile(url)
        } else {
            shadow.consumeCapture(snapshot)
        }

        return try await complete(with: shadow)
    }

    func cancel() async {
        collector?.setLiveHandler(nil)
        collector?.setDrainedHandler(nil)
        releaseFallback()
        await activeProvider?.cancelStreaming()
        await collector?.cleanupRecordingFile()
        endTake()
    }

    /// Runs the chosen provider's stop and releases the take either way.
    private func complete(with provider: any TranscriptionProvider) async throws -> String {
        let leftover = collector
        let result: String
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try await provider.stopStreaming()
            }.value
        } catch {
            await leftover?.cleanupRecordingFile()
            endTake()
            throw error
        }

        endTake()
        if let leftover {
            let generation = leftover.sessionGeneration
            Task(priority: .utility) {
                await leftover.cleanupRecordingFile(expectedGeneration: generation)
            }
        }
        return result
    }

    private func endTake() {
        takeGeneration &+= 1
        activeProvider = nil
        collector = nil
        pendingHints = []
        fallback = nil
        fallbackReadiness = nil
        primaryReadiness = .pending
        finishing = false
        // Nobody should still be waiting by now, but a stranded continuation would hang stop.
        let waiters = routeWaiters
        routeWaiters = []
        for waiter in waiters {
            waiter.resume(returning: .primary)
        }
    }

    // MARK: - Apple shadow

    private func startFallback(_ shadow: AppleSTTProvider, generation: UInt64) {
        Task {
            // Never prompts for Speech access and never downloads: if Apple cannot serve
            // silently, the take simply waits for its own engine as it always did.
            var started = false
            if await AppleSTTProvider.canServeAsFallback() {
                started = (try? await Task.detached(priority: .userInitiated) {
                    try await shadow.startStreaming()
                }.value) != nil
            }
            guard generation == takeGeneration, fallback === shadow else {
                // The take ended, or the selected engine came up first. `releaseFallback`
                // already cancelled once; this catches a start that completed afterwards.
                await shadow.cancelStreaming()
                return
            }
            if started {
                markFallback(.ready)
            } else {
                Latency.note("apple shadow unavailable — waiting on the selected engine")
                markFallback(.failed)
            }
        }
    }

    private func markPrimary(_ readiness: StopRoute.Readiness, generation: UInt64) {
        guard generation == takeGeneration else { return }
        primaryReadiness = readiness
        if readiness == .ready, !finishing {
            // Loaded mid-take. Stop listening with the shadow so it does not compete for the
            // Neural Engine for the rest of the take.
            releaseFallback()
            if let collector, let streamer = activeProvider as? StreamingAudioConsumer, streamer.wantsStreamingBuffers {
                collector.setDrainedHandler { [weak streamer] buffer in
                    streamer?.consumeStreamingBuffer(buffer)
                }
            } else {
                collector?.setDrainedHandler(nil)
            }
        }
        resolveWaiters()
    }

    private func markFallback(_ readiness: StopRoute.Readiness) {
        fallbackReadiness = readiness
        if readiness == .failed, !finishing {
            releaseFallback()
            fallbackReadiness = .failed
        }
        resolveWaiters()
    }

    private func resolveWaiters() {
        guard !routeWaiters.isEmpty,
              let route = StopRoute.resolve(primary: primaryReadiness, fallback: fallbackReadiness)
        else { return }
        let waiters = routeWaiters
        routeWaiters = []
        for waiter in waiters {
            waiter.resume(returning: route)
        }
    }

    /// Drops the shadow without touching the drained handler; callers re-route audio themselves.
    private func releaseFallback() {
        guard let shadow = fallback else { return }
        fallback = nil
        fallbackReadiness = nil
        Task.detached(priority: .utility) {
            await shadow.cancelStreaming()
            // The shadow took the warm pair; put one back for the next cold take.
            await AppleSTTProvider.prewarmAsFallback()
        }
    }

    private static func isCold(
        _ type: TranscriptionProviderType,
        whisperVariant: WhisperVariant,
        parakeetVariant: ParakeetVariant
    ) -> Bool {
        switch type {
        case .whisper:
            !WhisperKitProvider.isResident(variant: whisperVariant)
        case .parakeet:
            !ParakeetProvider.isResident(variant: parakeetVariant)
        case .apple, .deepgram, .mistral:
            false
        }
    }

    private func applyHints(_ hints: [String], to provider: any TranscriptionProvider) {
        if let apple = provider as? AppleSTTProvider {
            apple.setVocabularyHints(hints)
        }
        if let whisper = provider as? WhisperKitProvider {
            whisper.setVocabularyHints(hints)
        }
    }

    private func makeProvider(
        for type: TranscriptionProviderType,
        whisperVariant: WhisperVariant,
        parakeetVariant: ParakeetVariant
    ) -> any TranscriptionProvider {
        switch type {
        case .apple:
            AppleSTTProvider()
        case .whisper:
            WhisperKitProvider(variant: whisperVariant)
        case .parakeet:
            ParakeetProvider(variant: parakeetVariant)
        case .deepgram:
            DeepgramProvider()
        case .mistral:
            MistralProvider()
        }
    }
}
