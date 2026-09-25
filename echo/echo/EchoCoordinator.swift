import AppKit
import SwiftUI
import os

@Observable @MainActor
final class EchoCoordinator {
    static let shared = EchoCoordinator()

    let appState = AppState()
    private let hotkeyService = HotkeyService()
    private let audioEngine = AudioEngineService()
    private let transcriptionService = TranscriptionService()
    private let panelController = FloatingPanelController()
    private let stopIntent = StopIntentMonitor()
    private var startTask: Task<Void, Error>?
    private var captureTask: Task<Void, Error>?
    private var sceneTask: Task<Void, Never>?
    private var clipboardTask: Task<ClipboardSnapshot, Never>?
    private var wakeObservers: [NSObjectProtocol] = []
    /// Frontmost project terms for local replacements only. Never used to await model polish.
    private var activeScene: DictationScene?
    /// Stop → transcript milliseconds. Read only after paste in `deliver`.
    private var pendingRecognitionMs = 0.0
    /// Wall clock at the moment the user pressed stop. Used for the stop → paste figure.
    private var pendingStopAt: CFAbsoluteTime = 0
    /// Wall clock at the moment the take was started, for the first-audio figure.
    private var takePressedAt: CFAbsoluteTime = 0
    /// Clipboard captured during the take, restored after the paste.
    private var pendingClipboard: ClipboardSnapshot = []
    /// Bumped per take. A prepare that fails after its take ended must not abort the next one.
    private var takeGeneration: UInt64 = 0

    func start() {
        let launchedAt = CFAbsoluteTimeGetCurrent()

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
        Latency.launch(Latency.milliseconds(since: launchedAt))

        observeSystemWake()

        Task {
            let granted = await MicrophonePermission.request()
            if granted {
                audioEngine.prepareGraph()
            }
        }

        Task.detached(priority: .utility) {
            AudioSampleCollector.pruneStaleTemporaryRecordings()
            LocalModelPresence.rebuildAll()
            await Self.repairWhisperTokenizers()
            let records = LocalModelPresence.snapshot()
            await MainActor.run {
                ModelLibrary.shared.applyPresence(records)
                EchoCoordinator.shared.appState.repairEngineIfNeeded()
            }
            await Self.prewarmActiveDetached()
        }

        if !PasteService.isAccessibilityGranted {
            PasteService.requestAccessibility()
        }

        UsageStats.startBackgroundFlush()
        prewarmCleanup()

        #if DEBUG
        SpokenPathNormalizer.assertFixtureCases()
        #endif
    }

    /// The first cleanup of a run compiles its rules and regexes: ~45 ms between transcript and
    /// paste on the first take, ~4 ms after. Pay it once, after launch, instead.
    private func prewarmCleanup() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let settings = DictationSettings.shared
            let sample = "um so the build is green again and I think we can ship it on Thursday"
            _ = DictationCleanup.apply(
                sample,
                stripFillers: settings.stripFillers,
                vocabulary: settings.vocabulary,
                projectTerms: [],
                userReplacements: settings.replacements
            )
            _ = UsageWords.count(sample)
        }
    }

    func stop() {
        stopIntent.stop()
        sceneTask?.cancel()
        sceneTask = nil
        clipboardTask?.cancel()
        clipboardTask = nil
        for observer in wakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        wakeObservers = []
        hotkeyService.stop()
        audioEngine.teardown()
        ResidentEnginePolicy.cancelIdleUnload()
        ResidentEnginePolicy.evictEverything()
        AppChrome.endTakeActivity()
        Task.detached(priority: .utility) {
            await UsageStats.flushPending()
        }
    }

    /// Sleep parks CoreAudio and can invalidate the installed tap, and a napped process comes
    /// back with cold caches. Re-arm both instead of making the next take pay for it.
    private func observeSystemWake() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    EchoCoordinator.shared.handleSystemWake()
                }
            }
            wakeObservers.append(observer)
        }
    }

    private func handleSystemWake() {
        guard appState.phase == .idle else { return }
        Latency.note("system wake — re-arming audio graph and engine")
        AppChrome.beginIdleActivity()
        audioEngine.refreshGraph()
        Task.detached(priority: .utility) {
            await Self.prewarmActiveDetached()
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

    /// Order matters: everything before `panelController.show` is on the hotkey's critical path.
    ///
    /// Starting the microphone used to come first and it is a CoreAudio device start — tens of
    /// milliseconds warm, far more after the device has idled — so the overlay only appeared once
    /// the hardware was live. Capture now starts concurrently. Audio genuinely does not exist until
    /// the device is running, so a cold start still clips the first instant; what changed is that
    /// the user sees Echo listening immediately instead of staring at nothing.
    private func startRecording() {
        let pressedAt = CFAbsoluteTimeGetCurrent()

        if !appState.isLocalEngineReady() {
            appState.errorMessage = TranscriptionError.modelNotDownloaded.errorDescription
            return
        }

        ResidentEnginePolicy.cancelIdleUnload()
        AppChrome.beginTakeActivity()

        appState.partialTranscript = ""
        appState.errorMessage = nil
        appState.statusMessage = nil
        appState.audioLevels = Array(repeating: 0, count: OverlayMetrics.barCount)
        appState.phase = .recording
        sceneTask?.cancel()
        activeScene = nil
        panelController.show(appState: appState)
        Latency.hotkeyToChip(Latency.milliseconds(since: pressedAt))

        takePressedAt = pressedAt
        takeGeneration &+= 1
        let generation = takeGeneration
        let keepSamplesInMemory = appState.activeProvider != .apple
        let capture = Task(priority: .userInitiated) {
            let coldStart = try await audioEngine.beginCapture(keepSamplesInMemory: keepSamplesInMemory)
            Latency.engineRunning(Latency.milliseconds(since: pressedAt), restarted: coldStart)
        }
        captureTask = capture

        startTask = Task(priority: .userInitiated) {
            try await transcriptionService.prepare(
                providerType: appState.activeProvider,
                whisperVariant: appState.whisperVariant,
                parakeetVariant: appState.parakeetVariant,
                collector: audioEngine.sampleCollector,
                vocabularyHints: DictationSettings.shared.vocabulary
            )
        }

        // The stop shortcut's modifiers go down a beat before its key: start the tail then.
        stopIntent.start(modifiers: appState.hotkeyModifiers) {
            Task { @MainActor in
                EchoCoordinator.shared.anticipateStop()
            }
        }

        // Reading the previous clipboard can be slow when it holds an image or a file promise,
        // so it happens during the take rather than at paste time.
        clipboardTask = Task(priority: .utility) {
            PasteService.snapshotClipboard()
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
                try await capture.value
                try await startTask?.value
            } catch {
                guard appState.phase == .recording, takeGeneration == generation else { return }
                stopIntent.stop()
                await audioEngine.endCapture()
                await transcriptionService.cancel()
                appState.errorMessage = error.localizedDescription
                appState.phase = .idle
                panelController.hide()
                AppChrome.endTakeActivity()
                ResidentEnginePolicy.scheduleIdleUnload()
            }
        }
    }

    private func anticipateStop() {
        guard appState.phase == .recording else { return }
        transcriptionService.anticipateStop()
    }

    private func stopRecording() {
        stopIntent.stop()
        sceneTask?.cancel()
        appState.phase = .processing
        let provider = appState.activeProvider
        let start = startTask
        let capture = captureTask
        let stoppedAt = CFAbsoluteTimeGetCurrent()
        pendingStopAt = stoppedAt

        Task(priority: .userInitiated) {
            // Flush capture without cancelling if prepare is still finishing.
            if let delay = audioEngine.firstBufferDelay(since: takePressedAt) {
                Latency.firstBuffer(delay)
            }
            let flush = Task(priority: .userInitiated) { () -> (AudioCaptureSnapshot, Double) in
                let flushStart = CFAbsoluteTimeGetCurrent()
                let snapshot = await self.audioEngine.endCapture()
                return (snapshot, Latency.milliseconds(since: flushStart))
            }
            do {
                _ = try? await capture?.value
                // A cold Whisper / Parakeet can take tens of seconds to load. If its Apple shadow
                // is ready first, paste that rather than wait.
                let waitStart = CFAbsoluteTimeGetCurrent()
                let route = await transcriptionService.stopRoute()
                if route == .primary {
                    try await start?.value
                }
                let waitEngineMs = Latency.milliseconds(since: waitStart)
                let (snapshot, flushMs) = await flush.value
                let decodeStart = CFAbsoluteTimeGetCurrent()
                let raw = route == .fallback
                    ? try await transcriptionService.finishWithFallback(snapshot: snapshot)
                    : try await transcriptionService.finishAndTranscribe(snapshot: snapshot)
                let decodeMs = Latency.milliseconds(since: decodeStart)
                pendingRecognitionMs = Latency.milliseconds(since: stoppedAt)
                pendingClipboard = await clipboardTask?.value ?? []
                let servedByApple = provider == .apple || route == .fallback
                Latency.recognition(
                    pendingRecognitionMs,
                    provider: provider.rawValue,
                    seconds: snapshot.seconds,
                    streamed: servedByApple && AppleSTTProvider.lastTakeWasStreamed
                )
                Latency.stopBreakdown(
                    flush: flushMs,
                    waitEngine: waitEngineMs,
                    decode: decodeMs,
                    selected: provider.rawValue,
                    served: route == .fallback ? "apple-fallback" : provider.rawValue
                )
                deliver(raw)
            } catch {
                _ = await flush.value
                await transcriptionService.cancel()
                appState.errorMessage = error.localizedDescription
            }

            startTask = nil
            captureTask = nil
            clipboardTask = nil
            pendingClipboard = []
            appState.phase = .idle
            appState.partialTranscript = ""
            appState.audioLevels = Array(repeating: 0, count: OverlayMetrics.barCount)
            panelController.hide()
            AppChrome.endTakeActivity()
            ResidentEnginePolicy.scheduleIdleUnload()
        }
    }

    /// Paste after local cleanup only. Model polish used to block 350–900 ms and can shrink a take.
    private func deliver(_ raw: String) {
        if raw.isEmpty {
            pendingRecognitionMs = 0
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
        PasteService.paste(text: text, previousClipboard: pendingClipboard)
        let words = UsageWords.count(text)
        let pasteMs = (CFAbsoluteTimeGetCurrent() - pendingStopAt) * 1000
        UsageStats.recordSuccessfulPaste(
            wordCount: words,
            speechToTextMilliseconds: pendingRecognitionMs,
            pasteMilliseconds: pasteMs
        )
        Latency.paste(pasteMs, provider: appState.activeProvider.rawValue, words: words)
        pendingRecognitionMs = 0
        appState.statusMessage = "Pasted"
    }

    func prewarmAfterDownload(_ id: LocalModelID) {
        Task.detached(priority: .utility) {
            let (type, whisper, parakeet) = await MainActor.run {
                let state = EchoCoordinator.shared.appState
                return (state.activeProvider, state.whisperVariant, state.parakeetVariant)
            }
            switch id {
            case .whisper(let variant):
                guard type == .whisper, whisper == variant else { return }
                await Self.prewarm(type: .whisper, whisperVariant: variant, parakeetVariant: parakeet)
            case .parakeet(let variant):
                guard type == .parakeet, parakeet == variant else { return }
                await Self.prewarm(type: .parakeet, whisperVariant: whisper, parakeetVariant: variant)
            case .s1Mini:
                break
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
        let (type, whisper, parakeet) = await MainActor.run {
            let state = EchoCoordinator.shared.appState
            return (
                state.activeProvider,
                state.whisperVariant,
                state.parakeetVariant
            )
        }
        await prewarm(type: type, whisperVariant: whisper, parakeetVariant: parakeet)
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
        ResidentEnginePolicy.evictInactive(keeping: type)
        switch type {
        case .apple:
            await AppleSTTProvider.prewarm()
        case .whisper:
            // Apple first: it is small and quick, and it covers any take that starts before the
            // large graph finishes loading.
            await AppleSTTProvider.prewarmAsFallback()
            await WhisperKitProvider.prewarm(variant: whisperVariant)
        case .parakeet:
            await AppleSTTProvider.prewarmAsFallback()
            await ParakeetProvider.prewarm(variant: parakeetVariant)
        case .deepgram, .mistral:
            break
        }
        await MainActor.run {
            if EchoCoordinator.shared.appState.phase == .idle {
                ResidentEnginePolicy.scheduleIdleUnload()
            }
        }
    }
}
