import Foundation
import Testing
@testable import echo

@Suite("LocalModelPresence cache", .serialized)
struct LocalModelPresenceCacheTests {
    @Test func isReadyAfterSetDoesNotWalkDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-presence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        LocalModelPresence.rebuildAll(modelsRoot: root)
        LocalModelPresence.set(
            .s1Mini,
            record: PresenceRecord(ready: true, folder: root),
            modelsRoot: root
        )

        #expect(LocalModelPresence.isReady(.s1Mini))
        let took = HotPathBudget.elapsed {
            for _ in 0..<HotPathBudget.presenceLookupCount {
                precondition(LocalModelPresence.isReady(.s1Mini))
            }
        }
        #expect(took < HotPathBudget.cachedPresenceLookups, "\(HotPathBudget.presenceLookupCount) isReady calls took \(took) (budget \(HotPathBudget.cachedPresenceLookups))")
    }

    @Test func isReadyAfterRebuildHitsMemory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-presence-rebuild-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let s1 = LocalModelPaths.s1MiniDirectory(modelsRoot: root)
        try FileManager.default.createDirectory(at: s1, withIntermediateDirectories: true)
        for name in LocalModelPaths.s1RequiredFiles {
            FileManager.default.createFile(atPath: s1.appendingPathComponent(name).path, contents: Data())
        }

        LocalModelPresence.rebuild(.s1Mini, modelsRoot: root)
        #expect(LocalModelPresence.isReady(.s1Mini))

        let took = HotPathBudget.elapsed {
            for _ in 0..<HotPathBudget.presenceLookupCount {
                precondition(LocalModelPresence.isReady(.s1Mini))
            }
        }
        #expect(took < HotPathBudget.cachedPresenceLookups, "\(HotPathBudget.presenceLookupCount) isReady calls after rebuild took \(took) (budget \(HotPathBudget.cachedPresenceLookups))")
    }
}
