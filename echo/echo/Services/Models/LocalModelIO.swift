import Foundation
import FluidAudio
import WhisperKit

/// Downloads, deletes, and tokenizer repair. Never hop to MainActor.
nonisolated enum LocalModelIO: Sendable {
    static func download(
        _ id: LocalModelID,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        switch id {
        case .whisper(let variant):
            return try await downloadWhisper(variant, progress: progress)
        case .parakeet(let variant):
            return try await downloadParakeet(variant, progress: progress)
        case .s1Mini:
            return try await downloadS1Mini(progress: progress)
        }
    }

    static func delete(_ id: LocalModelID) throws {
        let root = LocalModelPaths.modelsRoot()
        let fm = FileManager.default
        var failures: [String] = []

        let urls: [URL]
        switch id {
        case .whisper(let variant):
            let persisted = LocalModelPresence.record(for: .whisper(variant))?.folder
            urls = LocalModelPaths.whisperDeleteURLs(
                downloadBase: LocalModelPaths.whisperDirectory(modelsRoot: root),
                variant: variant,
                persisted: persisted
            )
        case .parakeet(let variant):
            urls = LocalModelPaths.parakeetDeleteURLs(modelsRoot: root, variant: variant)
        case .s1Mini:
            urls = [LocalModelPaths.s1MiniDirectory(modelsRoot: root)]
        }

        for url in urls {
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if !failures.isEmpty {
            throw ModelTransferError(message: "Could not delete \(failures.joined(separator: "; "))")
        }
    }

    static func evictRuntimeCache(_ id: LocalModelID) async {
        switch id {
        case .whisper(let variant):
            WhisperKitProvider.evict(variant: variant)
        case .parakeet(let variant):
            ParakeetProvider.evict(variant: variant)
        case .s1Mini:
            await S1MiniEngine.shared.unload()
        }
    }

    private static func downloadWhisper(
        _ variant: WhisperVariant,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let downloadBase = LocalModelPaths.whisperDirectory()
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)

        let folder: URL
        do {
            folder = try await WhisperKit.download(
                variant: variant.rawValue,
                downloadBase: downloadBase
            ) { downloadProgress in
                progress(downloadProgress.fractionCompleted * 0.92)
            }
        } catch {
            throw ModelTransferError.from(error)
        }

        guard LocalModelPaths.whisperWeightsPresent(at: folder) else {
            let canonical = LocalModelPaths.whisperHubFolder(
                downloadBase: downloadBase,
                variantRawValue: variant.rawValue
            )
            if LocalModelPaths.whisperWeightsPresent(at: canonical) {
                try? await ensureTokenizer(variant, downloadBase: downloadBase, modelFolder: canonical)
                progress(1)
                return canonical
            }
            throw ModelTransferError(
                message: "Download finished but Whisper files were not at \(folder.path)."
            )
        }

        try? await ensureTokenizer(variant, downloadBase: downloadBase, modelFolder: folder)
        progress(1)
        return folder
    }

    static func ensureTokenizer(
        _ variant: WhisperVariant,
        downloadBase: URL,
        modelFolder: URL
    ) async throws {
        if LocalModelPaths.whisperTokenizerPresent(
            modelFolder: modelFolder,
            downloadBase: downloadBase,
            tokenizerRepository: variant.tokenizerRepository
        ) {
            return
        }

        let files = ["tokenizer.json", "tokenizer_config.json"]
        let base = URL(string: "https://huggingface.co/\(variant.tokenizerRepository)/resolve/main/")!
        for name in files {
            let target = modelFolder.appendingPathComponent(name)
            do {
                try await downloadFile(from: base.appendingPathComponent(name), to: target)
            } catch {
                if name == "tokenizer.json" { throw error }
            }
        }
        guard LocalModelPaths.whisperTokenizerPresent(
            modelFolder: modelFolder,
            downloadBase: downloadBase,
            tokenizerRepository: variant.tokenizerRepository
        ) else {
            throw ModelTransferError(message: "Download finished but the Whisper tokenizer is missing.")
        }
    }

    private static func downloadParakeet(
        _ variant: ParakeetVariant,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let root = LocalModelPaths.modelsRoot()
        let parent = LocalModelPaths.parakeetDirectory(modelsRoot: root)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = LocalModelPaths.parakeetRepoFolder(modelsRoot: root, variant: variant)
        let version: AsrModelVersion = variant == .v2English ? .v2 : .v3

        do {
            _ = try await AsrModels.download(to: target, version: version) { downloadProgress in
                progress(downloadProgress.fractionCompleted)
            }
        } catch {
            throw ModelTransferError.from(error)
        }

        guard AsrModels.modelsExist(at: target, version: version) else {
            throw ModelTransferError(
                message: "Download finished but Parakeet weights were not at \(LocalModelPaths.parakeetRepoFolderName(variant))."
            )
        }
        progress(1)
        return target
    }

    private static func downloadS1Mini(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let destination = LocalModelPaths.s1MiniDirectory()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let files = [
            "config.json",
            "generation_config.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "chat_template.jinja",
            "model.safetensors",
            "LICENSE",
        ]
        let base = URL(string: "https://huggingface.co/mlx-community/S1-mini-MLX-4bit/resolve/main/")!
        for (index, name) in files.enumerated() {
            let source = base.appendingPathComponent(name)
            let target = destination.appendingPathComponent(name)
            try await downloadFile(from: source, to: target)
            progress(Double(index + 1) / Double(files.count))
        }
        guard LocalModelPaths.s1MiniReady(at: destination) else {
            throw ModelTransferError(message: "Download finished but S1-mini files are incomplete.")
        }
        return destination
    }

    static func downloadFile(from source: URL, to target: URL) async throws {
        let (temp, response) = try await URLSession.shared.download(from: source)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temp)
            throw ModelTransferError(
                statusCode: http.statusCode,
                message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized
            )
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
    }
}
