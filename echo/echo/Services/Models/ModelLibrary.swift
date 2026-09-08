import Foundation
import os

@Observable @MainActor
final class ModelLibrary {
    static let shared = ModelLibrary()

    private struct Transfer {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private(set) var rows: [String: ModelRowSnapshot] = [:]
    private var lastProgressHop: [String: ContinuousClock.Instant] = [:]
    private var pendingProgress: [String: Double] = [:]
    private var transfers: [String: Transfer] = [:]

    var lastError: String? {
        rows.values.compactMap(\.error).last
    }

    private init() {}

    func row(_ id: LocalModelID) -> ModelRowSnapshot {
        if let existing = rows[id.id] {
            switch existing.status {
            case .downloading, .failed:
                return existing
            case .ready:
                if LocalModelPresence.isReady(id) { return existing }
            case .missing:
                break
            }
        }
        if LocalModelPresence.isReady(id) {
            return ModelRowSnapshot(status: .ready, progress: 1, error: nil)
        }
        return rows[id.id] ?? .missing
    }

    func isDownloaded(_ id: LocalModelID) -> Bool {
        isReady(id)
    }

    func isReady(_ id: LocalModelID) -> Bool {
        if rows[id.id]?.status == .downloading { return false }
        return LocalModelPresence.isReady(id)
    }

    func firstReadyWhisper() -> WhisperVariant? {
        WhisperVariant.allCases.first { isReady(.whisper($0)) }
    }

    func firstReadyParakeet() -> ParakeetVariant? {
        ParakeetVariant.allCases.first { isReady(.parakeet($0)) }
    }

    func applyPresence(_ records: [LocalModelID: PresenceRecord] = LocalModelPresence.snapshot()) {
        var next = rows
        for id in LocalModelID.all {
            let existing = next[id.id]
            if existing?.status == .downloading { continue }
            let record = records[id]
            if record?.ready == true {
                next[id.id] = ModelRowSnapshot(status: .ready, progress: 1, error: nil)
            } else if existing?.status == .failed {
                continue
            } else {
                next[id.id] = .missing
            }
        }
        rows = next
    }

    func download(_ id: LocalModelID) {
        if case .whisper(let variant) = id {
            EchoCoordinator.shared.appState.whisperVariant = variant
        }
        if case .parakeet(let variant) = id {
            EchoCoordinator.shared.appState.parakeetVariant = variant
        }

        var snap = rows[id.id] ?? .missing
        snap.status = .downloading
        snap.progress = 0
        snap.error = nil
        rows[id.id] = snap
        lastProgressHop[id.id] = nil

        let previous = transfers[id.id]
        let generation = (previous?.generation ?? 0) + 1
        previous?.task.cancel()

        let task = Task.detached(priority: .userInitiated) {
            _ = await previous?.task.result
            do {
                try Task.checkCancellation()
                let folder = try await LocalModelIO.download(id) { fraction in
                    if Task.isCancelled { return }
                    Task { @MainActor in
                        ModelLibrary.shared.noteProgress(id, fraction, generation: generation)
                    }
                }
                try Task.checkCancellation()
                LocalModelPresence.set(id, record: PresenceRecord(ready: true, folder: folder))
                LocalModelPresence.rebuild(id)
                guard LocalModelPresence.isReady(id) else {
                    throw ModelTransferError(message: "Download finished but the model files were not found.")
                }
                await MainActor.run {
                    ModelLibrary.shared.finishDownload(id, generation: generation)
                }
            } catch is CancellationError {
                return
            } catch {
                let transfer = ModelTransferError.from(error)
                LocalModelPresence.rebuild(id)
                await MainActor.run {
                    ModelLibrary.shared.finishFailed(id, generation: generation, transfer)
                }
            }
        }
        transfers[id.id] = Transfer(generation: generation, task: task)
    }

    func delete(_ id: LocalModelID) {
        var snap = rows[id.id] ?? .missing
        snap.error = nil
        rows[id.id] = snap

        let previous = transfers[id.id]
        let generation = (previous?.generation ?? 0) + 1
        previous?.task.cancel()

        let task = Task.detached(priority: .utility) {
            _ = await previous?.task.result
            do {
                try Task.checkCancellation()
                try LocalModelIO.delete(id)
                await LocalModelIO.evictRuntimeCache(id)
                LocalModelPresence.remove(id)
                await MainActor.run {
                    ModelLibrary.shared.finishDelete(id, generation: generation)
                }
            } catch is CancellationError {
                return
            } catch {
                let transfer = ModelTransferError.from(error)
                await MainActor.run {
                    ModelLibrary.shared.finishFailed(id, generation: generation, transfer)
                }
            }
        }
        transfers[id.id] = Transfer(generation: generation, task: task)
    }

    fileprivate func noteProgress(_ id: LocalModelID, _ value: Double, generation: UInt64) {
        guard transfers[id.id]?.generation == generation else { return }
        let now = ContinuousClock.now
        if let last = lastProgressHop[id.id], now - last < .milliseconds(100) {
            pendingProgress[id.id] = value
            return
        }
        lastProgressHop[id.id] = now
        pendingProgress[id.id] = nil
        rows[id.id]?.progress = value
        rows[id.id]?.status = .downloading
    }

    fileprivate func finishDownload(_ id: LocalModelID, generation: UInt64) {
        guard transfers[id.id]?.generation == generation else { return }
        transfers[id.id] = nil
        noteReady(id)
        EchoCoordinator.shared.prewarmAfterDownload(id)
    }

    fileprivate func finishDelete(_ id: LocalModelID, generation: UInt64) {
        guard transfers[id.id]?.generation == generation else { return }
        transfers[id.id] = nil
        noteRemoved(id)
        EchoCoordinator.shared.appState.repairEngineIfNeeded()
        if id == .s1Mini {
            let settings = DictationSettings.shared
            if settings.cleanupEngine == .s1Mini {
                settings.cleanupEngine = TranscriptCleaner.appleIntelligenceIsAvailable
                    ? .appleIntelligence
                    : .off
                settings.persist()
            }
        }
    }

    fileprivate func finishFailed(_ id: LocalModelID, generation: UInt64, _ error: ModelTransferError) {
        guard transfers[id.id]?.generation == generation else { return }
        transfers[id.id] = nil
        noteFailed(id, error)
    }

    private func noteReady(_ id: LocalModelID) {
        if let pending = pendingProgress[id.id] {
            rows[id.id]?.progress = pending
            pendingProgress[id.id] = nil
        }
        rows[id.id] = ModelRowSnapshot(status: .ready, progress: 1, error: nil)
    }

    private func noteFailed(_ id: LocalModelID, _ error: ModelTransferError) {
        let message = error.errorDescription ?? error.message
        rows[id.id] = ModelRowSnapshot(status: .failed, progress: 0, error: message)
        EchoCoordinator.shared.appState.errorMessage = message
    }

    private func noteRemoved(_ id: LocalModelID) {
        rows[id.id] = .missing
    }
}
