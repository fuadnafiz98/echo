import Foundation
import os

/// One local STT graph at a time. Cleanup models stay cold — polish is off the paste path.
///
/// Catalog / typical resident cost while warm:
/// - Whisper Tiny ~75 MB, Base ~145 MB, Small ~466 MB, Large Turbo ~626 MB
/// - Parakeet TDT 0.6B: ~600 MB on disk but only ~50 MB of footprint once loaded (measured,
///   2026-09-23: 50 → 97 MB). Reloading it can make ANECompilerService recompile the encoder,
///   which took 30–38 s on an M1 Pro, so it stays resident through idle and only goes on
///   critical pressure.
/// - S1-mini 4-bit ~400 MB (never kept warm)
/// - Apple SpeechAnalyzer warm pair: tens of MB
///
/// **Apple is never evicted while the app runs.** It costs tens of megabytes and evicting it meant
/// the first take after a quiet stretch paid a full model load, which is exactly the "sometimes it
/// takes ages" symptom. The large third-party graphs still unload, but on critical memory pressure
/// plus a long backstop timer rather than a ten-minute stopwatch, so an idle-but-in-use Echo stays
/// fast. A take that starts while its graph is cold is served by Apple Speech instead of waiting.
nonisolated enum ResidentEnginePolicy {
    /// Backstop only. Memory pressure is the real trigger.
    static let idleUnloadAfter: Duration = .seconds(2 * 60 * 60)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var idleTask: Task<Void, Never>?
    nonisolated(unsafe) private static var idleGeneration: UInt64 = 0
    nonisolated(unsafe) private static var pressureSource: DispatchSourceMemoryPressure?

    /// Set when pressure (not the idle backstop) unloaded the active graph, so the return to
    /// normal knows to load it again rather than leave the next take to pay for it.
    nonisolated(unsafe) private static var evictedByPressure = false

    /// Starts the memory-pressure watch. Safe to call more than once.
    ///
    /// Only `.critical` evicts. `.warning` fired about every half hour on a 32 GB machine with a
    /// third of its memory free, and each one threw away a 600 MB graph that then cost the next
    /// take a 20–40 s reload after stop. That was the 17.7 s take.
    static func startMemoryPressureWatch() {
        lock.lock()
        defer { lock.unlock() }
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler {
            lock.lock()
            let event = pressureSource?.data ?? []
            lock.unlock()
            handlePressure(event)
        }
        source.resume()
        pressureSource = source
    }

    private static func handlePressure(_ event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) {
            Task {
                let busy = await MainActor.run {
                    EchoCoordinator.shared.appState.phase != .idle
                }
                guard !busy else { return }
                Latency.note("memory pressure critical — unloading large speech graphs")
                lock.lock()
                evictedByPressure = true
                lock.unlock()
                evictLargeGraphs()
            }
        } else if event.contains(.warning) {
            Latency.note("memory pressure warning — keeping speech graphs resident")
        } else if event.contains(.normal) {
            lock.lock()
            let reload = evictedByPressure
            evictedByPressure = false
            lock.unlock()
            guard reload else { return }
            Latency.note("memory pressure cleared — re-warming active engine")
            Task { @MainActor in
                let coordinator = EchoCoordinator.shared
                guard coordinator.appState.phase == .idle else { return }
                coordinator.prewarmAfterUse(coordinator.appState.activeProvider)
            }
        }
    }

    static func evictInactive(keeping type: TranscriptionProviderType) {
        switch type {
        case .whisper:
            ParakeetProvider.evict()
        case .parakeet:
            WhisperKitProvider.evict()
        case .apple:
            WhisperKitProvider.evict()
            ParakeetProvider.evict()
        case .deepgram, .mistral:
            WhisperKitProvider.evict()
            ParakeetProvider.evict()
        }
        Task { await S1MiniEngine.shared.unload() }
    }

    /// Idle / pressure path. Deliberately leaves the Apple analyzer resident.
    static func evictLargeGraphs() {
        WhisperKitProvider.evict()
        ParakeetProvider.evict()
        Task { await S1MiniEngine.shared.unload() }
    }

    /// Idle backstop. Parakeet stays: it is cheap to keep and a reload can cost a 30 s compile.
    static func evictForIdle() {
        WhisperKitProvider.evict()
        Task { await S1MiniEngine.shared.unload() }
    }

    /// Quit path only.
    static func evictEverything() {
        WhisperKitProvider.evict()
        ParakeetProvider.evict()
        AppleSTTProvider.evict()
        Task { await S1MiniEngine.shared.unload() }
    }

    static func cancelIdleUnload() {
        lock.lock()
        idleGeneration &+= 1
        let task = idleTask
        idleTask = nil
        lock.unlock()
        task?.cancel()
    }

    static func scheduleIdleUnload() {
        startMemoryPressureWatch()
        lock.lock()
        idleGeneration &+= 1
        let generation = idleGeneration
        idleTask?.cancel()
        idleTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: idleUnloadAfter)
            guard !Task.isCancelled else { return }
            lock.lock()
            let stillCurrent = idleGeneration == generation
            lock.unlock()
            guard stillCurrent else { return }
            let busy = await MainActor.run {
                EchoCoordinator.shared.appState.phase != .idle
            }
            guard !busy else { return }
            Latency.note("idle backstop — unloading Whisper and cleanup models")
            evictForIdle()
        }
        lock.unlock()
    }
}
