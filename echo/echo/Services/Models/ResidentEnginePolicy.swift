import Foundation

/// One local STT graph at a time. Cleanup models stay cold — polish is off the paste path.
///
/// Catalog / typical resident cost while warm:
/// - Whisper Tiny ~75 MB, Base ~145 MB, Small ~466 MB, Large Turbo ~626 MB
/// - Parakeet TDT 0.6B ~600 MB
/// - S1-mini 4-bit ~400 MB (never kept warm)
/// - Apple SpeechAnalyzer warm pair: tens of MB
///
/// Selected Whisper / Parakeet stay loaded for first-stop latency, then unload
/// after ``idleUnloadAfter`` with no take in flight.
enum ResidentEnginePolicy {
    static let idleUnloadAfter: Duration = .seconds(10 * 60)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var idleTask: Task<Void, Never>?
    nonisolated(unsafe) private static var idleGeneration: UInt64 = 0

    static func evictInactive(keeping type: TranscriptionProviderType) {
        switch type {
        case .whisper:
            ParakeetProvider.evict()
            AppleSTTProvider.evict()
        case .parakeet:
            WhisperKitProvider.evict()
            AppleSTTProvider.evict()
        case .apple:
            WhisperKitProvider.evict()
            ParakeetProvider.evict()
        case .deepgram, .mistral:
            WhisperKitProvider.evict()
            ParakeetProvider.evict()
            AppleSTTProvider.evict()
        }
        Task { await S1MiniEngine.shared.unload() }
    }

    static func evictAllSpeech() {
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
            evictAllSpeech()
        }
        lock.unlock()
    }
}
