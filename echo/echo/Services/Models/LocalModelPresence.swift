import Foundation
import FluidAudio
import os

nonisolated struct PresenceRecord: Sendable, Equatable {
    var ready: Bool
    var folder: URL?
}

/// O(1) presence cache. Rebuild only on launch, download success, or delete.
nonisolated enum LocalModelPresence: Sendable {
    private static let state = OSAllocatedUnfairLock(initialState: [LocalModelID: PresenceRecord]())

    static func record(for id: LocalModelID) -> PresenceRecord? {
        state.withLock { $0[id] }
    }

    static func folder(for id: LocalModelID) -> URL? {
        let record = resolved(id)
        return record.ready ? record.folder : nil
    }

    static func isReady(_ id: LocalModelID) -> Bool {
        resolved(id).ready
    }

    /// Memory hit after the first probe. One known-path `fileExists` check if the cache is cold.
    private static func resolved(_ id: LocalModelID) -> PresenceRecord {
        if let record = state.withLock({ $0[id] }) {
            return record
        }
        let modelsRoot = LocalModelPaths.modelsRoot()
        let persisted = loadPersisted(modelsRoot: modelsRoot)[id.id]
        let record = probe(id, modelsRoot: modelsRoot, persisted: persisted)
        state.withLock { $0[id] = record }
        return record
    }

    static func snapshot() -> [LocalModelID: PresenceRecord] {
        state.withLock { $0 }
    }

    static func set(
        _ id: LocalModelID,
        record: PresenceRecord,
        modelsRoot: URL = LocalModelPaths.modelsRoot()
    ) {
        state.withLock { $0[id] = record }
        persistLocked(modelsRoot: modelsRoot)
    }

    static func remove(_ id: LocalModelID) {
        state.withLock { $0[id] = PresenceRecord(ready: false, folder: nil) }
        persistLocked()
    }

    static func rebuildAll(modelsRoot: URL = LocalModelPaths.modelsRoot()) {
        let persisted = loadPersisted(modelsRoot: modelsRoot)
        var next: [LocalModelID: PresenceRecord] = [:]
        for id in LocalModelID.all {
            next[id] = probe(id, modelsRoot: modelsRoot, persisted: persisted[id.id])
        }
        let frozen = next
        state.withLock { $0 = frozen }
        persist(records: frozen, modelsRoot: modelsRoot)
    }

    static func rebuild(_ id: LocalModelID, modelsRoot: URL = LocalModelPaths.modelsRoot()) {
        let persisted = loadPersisted(modelsRoot: modelsRoot)
        let record = probe(id, modelsRoot: modelsRoot, persisted: persisted[id.id])
        state.withLock { $0[id] = record }
        persistLocked(modelsRoot: modelsRoot)
    }

    private static func probe(
        _ id: LocalModelID,
        modelsRoot: URL,
        persisted: String?
    ) -> PresenceRecord {
        switch id {
        case .whisper(let variant):
            let downloadBase = LocalModelPaths.whisperDirectory(modelsRoot: modelsRoot)
            var candidates: [URL] = [
                LocalModelPaths.whisperHubFolder(downloadBase: downloadBase, variantRawValue: variant.rawValue)
            ]
            if let persisted, let url = URL(string: persisted) ?? optionalFileURL(persisted) {
                if !candidates.contains(url) { candidates.insert(url, at: 0) }
            }
            if let folder = candidates.first(where: { LocalModelPaths.whisperWeightsPresent(at: $0) }) {
                return PresenceRecord(ready: true, folder: folder)
            }
            return PresenceRecord(ready: false, folder: candidates.first)

        case .parakeet(let variant):
            let version: AsrModelVersion = variant == .v2English ? .v2 : .v3
            let repo = LocalModelPaths.parakeetRepoFolder(modelsRoot: modelsRoot, variant: variant)
            var candidates = [repo]
            if let persisted, let url = optionalFileURL(persisted), !candidates.contains(url) {
                candidates.insert(url, at: 0)
            }
            if let folder = candidates.first(where: { AsrModels.modelsExist(at: $0, version: version) }) {
                return PresenceRecord(ready: true, folder: folder)
            }
            return PresenceRecord(ready: false, folder: repo)

        case .s1Mini:
            let folder = LocalModelPaths.s1MiniDirectory(modelsRoot: modelsRoot)
            if LocalModelPaths.s1MiniReady(at: folder) {
                return PresenceRecord(ready: true, folder: folder)
            }
            return PresenceRecord(ready: false, folder: folder)
        }
    }

    private static func optionalFileURL(_ raw: String) -> URL? {
        if raw.hasPrefix("/") || raw.hasPrefix("file:") {
            return URL(fileURLWithPath: raw.replacingOccurrences(of: "file://", with: ""))
        }
        return nil
    }

    private static func loadPersisted(modelsRoot: URL) -> [String: String] {
        let url = LocalModelPaths.presenceIndexURL(modelsRoot: modelsRoot)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func persistLocked(modelsRoot: URL = LocalModelPaths.modelsRoot()) {
        persist(records: state.withLock { $0 }, modelsRoot: modelsRoot)
    }

    private static func persist(records: [LocalModelID: PresenceRecord], modelsRoot: URL) {
        var payload: [String: String] = [:]
        for (id, record) in records {
            if record.ready, let folder = record.folder {
                payload[id.id] = folder.path
            }
        }
        let url = LocalModelPaths.presenceIndexURL(modelsRoot: modelsRoot)
        try? FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
