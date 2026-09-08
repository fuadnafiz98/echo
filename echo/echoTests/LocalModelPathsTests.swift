import Foundation
import Testing
@testable import echo

@Suite("LocalModelPaths")
struct LocalModelPathsTests {
    @Test func whisperAndParakeetFoldersAreCanonical() {
        let root = URL(fileURLWithPath: "/tmp/echo-model-paths-tests")
        let downloadBase = LocalModelPaths.whisperDirectory(modelsRoot: root)
        let small = LocalModelPaths.whisperHubFolder(downloadBase: downloadBase, variantRawValue: "small.en")
        #expect(small.path.hasSuffix("whisperkit/models/argmaxinc/whisperkit-coreml/openai_whisper-small.en"))
        #expect(!small.path.hasSuffix("/whisperkit/openai_whisper-small.en"))

        let parakeet = LocalModelPaths.parakeetRepoFolder(modelsRoot: root, variant: .v2English)
        #expect(parakeet.lastPathComponent == "parakeet-tdt-0.6b-v2")
        #expect(LocalModelPaths.parakeetLegacyAlias(modelsRoot: root, variant: .v2English).lastPathComponent == "v2")
    }

    @Test func weightChecksUseKnownFilesNotADirectoryWalk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-path-weights-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        let fake = root.appendingPathComponent("fake-small", isDirectory: true)
        try fm.createDirectory(at: fake, withIntermediateDirectories: true)
        #expect(!LocalModelPaths.whisperWeightsPresent(at: fake, fileManager: fm))
        for name in ["config.json", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
            fm.createFile(atPath: fake.appendingPathComponent(name).path, contents: Data())
        }
        #expect(LocalModelPaths.whisperWeightsPresent(at: fake, fileManager: fm))

        let s1 = LocalModelPaths.s1MiniDirectory(modelsRoot: root)
        try fm.createDirectory(at: s1, withIntermediateDirectories: true)
        #expect(!LocalModelPaths.s1MiniReady(at: s1, fileManager: fm))
        for name in LocalModelPaths.s1RequiredFiles {
            fm.createFile(atPath: s1.appendingPathComponent(name).path, contents: Data())
        }
        #expect(LocalModelPaths.s1MiniReady(at: s1, fileManager: fm))
    }
}
