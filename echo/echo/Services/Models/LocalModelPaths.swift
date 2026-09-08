import Foundation

/// Canonical on-disk locations. No directory walks. Safe to call from any isolation.
nonisolated enum LocalModelPaths: Sendable {
    static let whisperHubOwner = "argmaxinc"
    static let whisperHubRepo = "whisperkit-coreml"

    static func applicationSupport() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static func modelsRoot(appSupport: URL = applicationSupport()) -> URL {
        appSupport.appendingPathComponent("Echo/Models", isDirectory: true)
    }

    static func whisperDirectory(modelsRoot: URL = modelsRoot()) -> URL {
        modelsRoot.appendingPathComponent("whisperkit", isDirectory: true)
    }

    static func parakeetDirectory(modelsRoot: URL = modelsRoot()) -> URL {
        modelsRoot.appendingPathComponent("parakeet", isDirectory: true)
    }

    static func s1MiniDirectory(modelsRoot: URL = modelsRoot()) -> URL {
        modelsRoot.appendingPathComponent("s1-mini", isDirectory: true)
    }

    static func presenceIndexURL(modelsRoot: URL = modelsRoot()) -> URL {
        modelsRoot.appendingPathComponent("presence.json", isDirectory: false)
    }

    /// WhisperKit Hub tree: `downloadBase/models/argmaxinc/whisperkit-coreml/openai_whisper-<variant>/`
    static func whisperHubFolder(downloadBase: URL, variantRawValue: String) -> URL {
        downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(whisperHubOwner, isDirectory: true)
            .appendingPathComponent(whisperHubRepo, isDirectory: true)
            .appendingPathComponent(whisperFolderName(variantRawValue), isDirectory: true)
    }

    static func whisperFolderName(_ variantRawValue: String) -> String {
        "openai_whisper-\(variantRawValue)"
    }

    static func whisperTokenizerFolder(downloadBase: URL, tokenizerRepository: String) -> URL {
        let parts = tokenizerRepository.split(separator: "/").map(String.init)
        var url = downloadBase.appendingPathComponent("models", isDirectory: true)
        for part in parts {
            url.appendPathComponent(part, isDirectory: true)
        }
        return url
    }

    static func whisperWeightsPresent(at folder: URL, fileManager: FileManager = .default) -> Bool {
        let required = ["config.json", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        return required.allSatisfy { name in
            fileManager.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
    }

    static func whisperTokenizerPresent(
        modelFolder: URL,
        downloadBase: URL,
        tokenizerRepository: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let names = ["tokenizer.json"]
        let folders = [
            modelFolder,
            whisperTokenizerFolder(downloadBase: downloadBase, tokenizerRepository: tokenizerRepository),
        ]
        return folders.contains { folder in
            names.allSatisfy { fileManager.fileExists(atPath: folder.appendingPathComponent($0).path) }
        }
    }

    /// FluidAudio `Repo.folderName` strips `-coreml` from Parakeet v2/v3.
    static func parakeetRepoFolderName(_ variant: ParakeetVariant) -> String {
        switch variant {
        case .v2English: "parakeet-tdt-0.6b-v2"
        case .v3Multilingual: "parakeet-tdt-0.6b-v3"
        }
    }

    static func parakeetRepoFolder(modelsRoot: URL = modelsRoot(), variant: ParakeetVariant) -> URL {
        parakeetDirectory(modelsRoot: modelsRoot)
            .appendingPathComponent(parakeetRepoFolderName(variant), isDirectory: true)
    }

    /// Legacy Echo folder that must never count as ready.
    static func parakeetLegacyAlias(modelsRoot: URL = modelsRoot(), variant: ParakeetVariant) -> URL {
        parakeetDirectory(modelsRoot: modelsRoot)
            .appendingPathComponent(variant.rawValue, isDirectory: true)
    }

    static func parakeetDeleteURLs(modelsRoot: URL = modelsRoot(), variant: ParakeetVariant) -> [URL] {
        let parent = parakeetDirectory(modelsRoot: modelsRoot)
        let name = parakeetRepoFolderName(variant)
        return [
            parent.appendingPathComponent(name, isDirectory: true),
            parent.appendingPathComponent("\(name)-coreml", isDirectory: true),
            parakeetLegacyAlias(modelsRoot: modelsRoot, variant: variant),
        ]
    }

    static let s1RequiredFiles = ["config.json", "model.safetensors", "tokenizer.json"]

    static func s1MiniReady(at folder: URL, fileManager: FileManager = .default) -> Bool {
        s1RequiredFiles.allSatisfy { name in
            fileManager.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
    }

    static func whisperDeleteURLs(
        downloadBase: URL,
        variant: WhisperVariant,
        persisted: URL?
    ) -> [URL] {
        var urls = [
            whisperHubFolder(downloadBase: downloadBase, variantRawValue: variant.rawValue),
            whisperTokenizerFolder(downloadBase: downloadBase, tokenizerRepository: variant.tokenizerRepository),
        ]
        if let persisted, !urls.contains(persisted) {
            urls.append(persisted)
        }
        return urls
    }
}
