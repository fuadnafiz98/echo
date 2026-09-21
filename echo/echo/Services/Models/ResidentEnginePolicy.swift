import Foundation
import os

/// One local STT graph at a time. Cleanup models stay cold — polish is off the paste path.
///
/// Catalog / typical resident cost while warm:
/// - Whisper Tiny ~75 MB, Base ~145 MB, Small ~466 MB, Large Turbo ~626 MB
/// - Parakeet TDT 0.6B ~600 MB
/// - S1-mini 4-bit ~400 MB (never kept warm)
/// - Apple SpeechAnalyzer warm pair: tens of MB
///
/// **Apple is never evicted while the app runs.** It costs tens of megabytes and evicting it meant
/// the first take after a quiet stretch paid a full model load, which is exactly the "sometimes it
/// takes ages" symptom. The large third-party graphs still unload, but on memory pressure plus a
/// long backstop timer rather than a ten-minute stopwatch, so an idle-but-in-use Echo stays fast.
nonisolated enum ResidentEnginePolicy {
    /// Backstop only. Memory pressure is the real trigger.
    static let idleUnloadAfter: Duration = .seconds(2 * 60 * 60)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var idleTask: Task<Void, Never>?
    nonisolated(unsafe) private static var idleGeneration: UInt64 = 0
    nonisolated(unsafe) private static var pressureSource: DispatchSourceMemoryPressure?

    /// Starts the memory-pressure watch. Safe to call more than once.
    static func startMemoryPressureWatch() {
        lock.lock()
        defer { lock.unlock() }
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler {
            Task {
                let busy = await MainActor.run {
                    EchoCoordinator.shared.appState.phase != .idle
                }
                guard !busy else { return }
                Latency.note("memory pressure — unloading large speech graphs")
                evictLargeGraphs()
            }
        }
        source.resume()
        pressureSource = source
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
            evictLargeGraphs()
        }
        lock.unlock()
    }
}
