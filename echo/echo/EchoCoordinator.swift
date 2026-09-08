import os
import SwiftUI

@Observable @MainActor
final class EchoCoordinator {
    static let shared = EchoCoordinator()
    private static let latencyLog = Logger(subsystem: "echo", category: "latency")

    let appState = AppState()
    private let hotkeyService = HotkeyService()
    private let audioEngine = AudioEngineService()
    private let transcriptionService = TranscriptionService()
    private let panelController = FloatingPanelController()
    private var startTask: Task<Void, Error>?
    private var sceneTask: Task<Void, Never>?
    /// Frontmost project terms for local replacements only. Never used to await model polish.
    private var activeScene: DictationScene?

    func start() {
        hotkeyService.configure(
            keyCode: appState.hotkeyKeyCode,
            modifiers: appState.hotkeyModifiers,
            onToggle: { [weak self] in
                self?.toggle()
            }
        )

        panelController.levelsProvider = { [weak audioEngine] in
            audioEngine?.pullLevels() ?? []
        }

        hotkeyService.start()
        panelController.prewarm()

        Task {
            let granted = await MicrophonePermission.request()
            if granted {
                try? audioEngine.prepareGraph()
            }
        }

        Task.detached(priority: .utility) {
            LocalModelPresence.rebuildAll()
            await Self.repairWhisperTokenizers()
            let records = LocalModelPresence.snapshot()
            await MainActor.run {
                ModelLibrary.shared.applyPresence(records)
                EchoCoordinator.shared.appState.repairEngineIfNeeded()
            }
            await Self.prewarmActiveDetached()
        }

        Task {
            await BackdropSampler.prewarm()
        }

        if !PasteService.isAccessibilityGranted {
            PasteService.requestAccessibility()
        }

        UsageStats.startBackgroundFlush()
        ResourceStats.startBackgroundPersist()

        #if DEBUG
        SpokenPathNormalizer.assertFixtureCases()
        #endif
    }

    func stop() {
        sceneTask?.cancel()
        sceneTask = nil
        hotkeyService.stop()
        audioEngine.teardown()
        Task.detached(priority: .utility) {
            await UsageStats.flushPending()
        }
    }

    func updateShortcut(keyCode: UInt16, modifiers: CGEventFlags) {
        appState.hotkeyKeyCode = keyCode
        appState.hotkeyModifiers = modifiers
        hotkeyService.updateShortcut(keyCode: keyCode, modifiers: modifiers)
    }

    func setCapturingShortcut(_ capturing: Bool) {
        if capturing {
            hotkeyService.suspend()
        } else {
            hotkeyService.resume()
        }
    }

    func toggle() {
        switch appState.phase {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .processing:
            break
        }
    }

    private func startRecording() {
        if !appState.isLocalEngineReady() {
            appState.errorMessage = TranscriptionError.modelNotDownloaded.errorDescription
            return
        }

        do {
            try audioEngine.beginCapture(keepSamplesInMemory: appState.activeProvider != .apple)
        } catch {
            appState.errorMessage = error.localizedDescription
            return
        }

        appState.partialTranscript = ""
        appState.errorMessage = nil
        appState.statusMessage = nil
        appState.audioLevels = Array(repeating: 0, count: OverlayMetrics.barCount)
        appState.phase = .recording
        sceneTask?.cancel()
        activeScene = nil
        panelController.show(appState: appState)

        startTask = Task(priority: .userInitiated) {
            try await transcriptionService.prepare(
                providerType: appState.activeProvider,
                whisperVariant: appState.whisperVariant,
                parakeetVariant: appState.parakeetVariant,
                collector: audioEngine.sampleCollector
            )
        }

        sceneTask = Task {
            let settings = DictationSettings.shared
            let scene = await FrontmostContext.capture(scanProject: settings.useFrontmostProject)
            guard !Task.isCancelled else { return }
            activeScene = scene
            guard appState.phase == .recording else { return }
            transcriptionService.setVocabularyHints(VocabIndex.speechHints(scene: scene, settings: settings))
        }

        Task {
            do {
                try await startTask?.value
            } catch {
                guard appState.phase == .recording else { return }
                await audioEngine.endCapture()
                await transcriptionService.cancel()
                appState.errorMessage = error.localizedDescription
                appState.phase = .idle
                panelController.hide()
            }
        }
    }

    private func stopRecording() {
        sceneTask?.cancel()
        panelController.stopBackdropSampling()
        appState.phase = .processing
        let provider = appState.activeProvider
        let start = startTask

        Task(priority: .userInitiated) {
            #if DEBUG
            let t0 = CFAbsoluteTimeGetCurrent()
            #endif

            // Flush capture without cancelling if prepare is still finishing.
            let capture = Task(priority: .userInitiated) { await self.audioEngine.endCapture() }
            do {
                try await start?.value
                let snapshot = await capture.value
                let raw = try await transcriptionService.finishAndTranscribe(snapshot: snapshot)
                deliver(raw)
                #if DEBUG
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                Self.latencyLog.debug(
                    "stop→paste \(ms, format: .fixed(precision: 1))ms provider=\(provider.rawValue, privacy: .public) samples=\(snapshot.samples.count)"
                )
                #endif
            } catch {
                _ = await capture.value
                await transcriptionService.cancel()
                appState.errorMessage = error.localizedDescription
            }

            startTask = nil
            appState.phase = .idle
            appState.partialTranscript = ""
            appState.audioLevels = Array(repeating: 0, count: OverlayMetrics.barCount)
            panelController.hide()
        }
    }

    /// Paste after local cleanup only. Model polish used to block 350–900 ms and can shrink a take.
    private func deliver(_ raw: String) {
        if raw.isEmpty {
            appState.presentEmptyTakeError()
            return
        }
        let settings = DictationSettings.shared
        let projectTerms = settings.useFrontmostProject ? (activeScene?.projectTerms ?? []) : []
        let text = DictationCleanup.apply(
            raw,
            stripFillers: settings.stripFillers,
            vocabulary: settings.vocabulary,
            projectTerms: projectTerms,
            userReplacements: settings.replacements
        )
        PasteService.paste(text: text)
        UsageStats.recordSuccessfulPaste(wordCount: UsageWords.count(text))
        appState.statusMessage = "Pasted"
    }

    func prewarmAfterDownload(_ id: LocalModelID) {
        Task.detached(priority: .utility) {
            switch id {
            case .whisper(let variant):
                await WhisperKitProvider.prewarm(variant: variant)
            case .parakeet(let variant):
                await ParakeetProvider.prewarm(variant: variant)
            case .s1Mini:
                let wantsS1 = await MainActor.run { DictationSettings.shared.cleanupEngine == .s1Mini }
                if wantsS1 {
                    await S1MiniEngine.shared.prewarmFromPresence()
                }
            }
        }
    }

    func prewarmAfterUse(_ type: TranscriptionProviderType) {
        let whisper = appState.whisperVariant
        let parakeet = appState.parakeetVariant
        Task.detached(priority: .utility) {
            await Self.prewarm(type: type, whisperVariant: whisper, parakeetVariant: parakeet)
        }
    }

    private static func prewarmActiveDetached() async {
        let (type, whisper, parakeet, cleanup) = await MainActor.run {
            let state = EchoCoordinator.shared.appState
            return (
                state.activeProvider,
                state.whisperVariant,
                state.parakeetVariant,
                DictationSettings.shared.cleanupEngine
            )
        }
        await prewarm(type: type, whisperVariant: whisper, parakeetVariant: parakeet)
        switch cleanup {
        case .s1Mini:
            await S1MiniEngine.shared.prewarmFromPresence()
        case .appleIntelligence:
            await MainActor.run { TranscriptCleaner.shared.prewarm() }
        case .off:
            break
        }
    }

    private static func repairWhisperTokenizers() async {
        let downloadBase = LocalModelPaths.whisperDirectory()
        for variant in WhisperVariant.allCases {
            let id = LocalModelID.whisper(variant)
            guard LocalModelPresence.isReady(id),
                  let folder = LocalModelPresence.folder(for: id)
            else { continue }
            try? await LocalModelIO.ensureTokenizer(
                variant,
                downloadBase: downloadBase,
                modelFolder: folder
            )
        }
    }

    private static func prewarm(
        type: TranscriptionProviderType,
        whisperVariant: WhisperVariant,
        parakeetVariant: ParakeetVariant
    ) async {
        switch type {
        case .apple:
            await AppleSTTProvider.prewarm()
        case .whisper:
            await WhisperKitProvider.prewarm(variant: whisperVariant)
        case .parakeet:
            await ParakeetProvider.prewarm(variant: parakeetVariant)
        case .deepgram, .mistral:
            break
        }
    }
}
