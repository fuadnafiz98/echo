import Foundation

@main
enum LocalModelPathsVerify {
    static func main() {
        var failed = 0

        func expect(_ condition: Bool, _ message: String) {
            if condition {
                print("PASS  \(message)")
            } else {
                failed += 1
                print("FAIL  \(message)")
            }
        }

        let root = URL(fileURLWithPath: "/tmp/echo-model-paths")
        let downloadBase = LocalModelPaths.whisperDirectory(modelsRoot: root)
        let small = LocalModelPaths.whisperHubFolder(downloadBase: downloadBase, variantRawValue: "small.en")
        expect(
            small.path.hasSuffix("whisperkit/models/argmaxinc/whisperkit-coreml/openai_whisper-small.en"),
            "Whisper Small Hub path is canonical"
        )
        expect(
            !small.path.hasSuffix("/whisperkit/openai_whisper-small.en"),
            "Whisper path is not a shallow whisperkit child"
        )

        let parakeet = LocalModelPaths.parakeetRepoFolder(modelsRoot: root, variant: .v2English)
        expect(
            parakeet.lastPathComponent == "parakeet-tdt-0.6b-v2",
            "Parakeet v2 uses FluidAudio folderName"
        )
        expect(
            LocalModelPaths.parakeetLegacyAlias(modelsRoot: root, variant: .v2English).lastPathComponent == "v2",
            "Legacy v2/ alias is not the repo folder"
        )

        let fm = FileManager.default
        let fake = root.appendingPathComponent("fake-small", isDirectory: true)
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: fake, withIntermediateDirectories: true)
        expect(!LocalModelPaths.whisperWeightsPresent(at: fake, fileManager: fm), "Empty folder is not ready")
        for name in ["config.json", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
            fm.createFile(atPath: fake.appendingPathComponent(name).path, contents: Data())
        }
        expect(LocalModelPaths.whisperWeightsPresent(at: fake, fileManager: fm), "Weights-only tree is ready")

        let s1 = LocalModelPaths.s1MiniDirectory(modelsRoot: root)
        try? fm.createDirectory(at: s1, withIntermediateDirectories: true)
        expect(!LocalModelPaths.s1MiniReady(at: s1, fileManager: fm), "Empty s1-mini is not ready")
        for name in LocalModelPaths.s1RequiredFiles {
            fm.createFile(atPath: s1.appendingPathComponent(name).path, contents: Data())
        }
        expect(LocalModelPaths.s1MiniReady(at: s1, fileManager: fm), "S1 required files mark ready")

        let liveRoot = LocalModelPaths.modelsRoot()
        let liveSmall = LocalModelPaths.whisperHubFolder(
            downloadBase: LocalModelPaths.whisperDirectory(modelsRoot: liveRoot),
            variantRawValue: "small.en"
        )
        let liveS1 = LocalModelPaths.s1MiniDirectory(modelsRoot: liveRoot)
        expect(
            LocalModelPaths.whisperWeightsPresent(at: liveSmall),
            "On-disk Whisper Small is detected at \(liveSmall.path)"
        )
        expect(
            LocalModelPaths.s1MiniReady(at: liveS1),
            "On-disk S1-mini is detected at \(liveS1.path)"
        )

        try? fm.removeItem(at: root)
        if failed > 0 {
            print("FAILED \(failed)")
            exit(1)
        }
        print("OK")
    }
}
