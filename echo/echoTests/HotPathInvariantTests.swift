import Testing
@testable import echo

@Suite("Hot-path source invariants")
struct HotPathInvariantTests {
    @Test func deliverStaysLocalAndSynchronous() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let deliver = try #require(AppSource.method(source, named: "deliver"))
        #expect(deliver.contains("DictationCleanup.apply"))
        #expect(!deliver.contains("TranscriptCleaner"))
        #expect(!deliver.contains("S1Mini"))
        #expect(!deliver.contains("polish"))
        #expect(!deliver.contains("await"))
    }

    @Test func stopRecordingDoesNotAwaitModelPolish() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let stop = try #require(AppSource.method(source, named: "stopRecording"))
        #expect(stop.contains("deliver(raw)"))
        #expect(!stop.contains("TranscriptCleaner"))
        #expect(!stop.contains("S1MiniEngine"))
        #expect(!stop.contains("polish("))
    }

    /// The overlay must be on screen before the microphone is asked to start. `engine.start()` is
    /// a CoreAudio device start and can take hundreds of milliseconds on a cold device.
    @Test func startRecordingShowsOverlayBeforeStartingCapture() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let start = try #require(AppSource.method(source, named: "startRecording"))
        #expect(
            AppSource.appearsInOrder(start, [
                "appState.phase = .recording",
                "panelController.show",
                "audioEngine.beginCapture",
            ]),
            "startRecording must show the chip before starting capture. Got:\n\(start)"
        )
        // Capture is awaited, never run synchronously on the hotkey's thread.
        #expect(start.contains("try await audioEngine.beginCapture"))
    }

    /// Nothing on the hotkey path may block on the disk.
    @Test func beginSessionNeverBlocksOnIO() throws {
        let source = try AppSource.load("Services/Audio/AudioSampleCollector.swift")
        let begin = try #require(AppSource.method(source, named: "beginSession"))
        #expect(!begin.contains("ioQueue.sync"))
        #expect(!begin.contains("contentsOfDirectory"))
        #expect(begin.contains("ioQueue.async"))
    }

    @Test func startRecordingDoesNotDownloadOrWalkDisk() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let start = try #require(AppSource.method(source, named: "startRecording"))
        #expect(start.contains("beginCapture"))
        #expect(start.contains("panelController.show"))
        #expect(!start.contains("download("))
        #expect(!start.contains("contentsOfDirectory"))
        #expect(!start.contains("TranscriptCleaner"))
        #expect(!start.contains("LocalModelIO"))
        #expect(!start.contains("rebuildAll"))
        #expect(!start.contains("UsageStats"))
        #expect(!start.contains("ResourceStats"))
        #expect(!start.contains("GPUMetrics"))
        #expect(!start.contains("task_info"))
    }

    @Test func finishAndTranscribeDoesNotTrimCAFFirst() throws {
        let source = try AppSource.load("Services/Transcription/TranscriptionService.swift")
        let finish = try #require(AppSource.method(source, named: "finishAndTranscribe"))
        #expect(!finish.contains("trimSilence"))
        #expect(!finish.contains("trimmingSilence"))
    }

    @Test func deliverDoesNotPersistStatsOrSampleProcess() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let deliver = try #require(AppSource.method(source, named: "deliver"))
        #expect(deliver.contains("UsageStats.recordSuccessfulPaste"))
        #expect(deliver.contains("UsageWords.count"))
        #expect(
            AppSource.appearsInOrder(deliver, [
                "DictationCleanup.apply",
                "PasteService.paste",
                "UsageStats.recordSuccessfulPaste",
            ]),
            "deliver must cleanup, then paste, then record. Got:\n\(deliver)"
        )
        #expect(!deliver.contains("flushPending"))
        #expect(!deliver.contains("UsageStatsStore"))
        #expect(!deliver.contains("ResourceStats"))
        #expect(!deliver.contains("GPUMetrics"))
        #expect(!deliver.contains("resources.json"))
        #expect(!deliver.contains("JSONEncoder"))
        #expect(!deliver.contains("JSONDecoder"))
        #expect(!deliver.contains("write(to:"))
        #expect(!deliver.contains("task_info"))
        #expect(!deliver.contains("host_processor"))
        #expect(!deliver.contains("IOAccelerator"))
        #expect(!deliver.contains("AGXAccelerator"))
        #expect(!deliver.contains("Task.detached"))
        #expect(!deliver.contains("await"))
    }

    @Test func stopAndStartRecordingStayClearOfStatsIO() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let stop = try #require(AppSource.method(source, named: "stopRecording"))
        let start = try #require(AppSource.method(source, named: "startRecording"))
        for body in [stop, start] {
            #expect(!body.contains("UsageStats"))
            #expect(!body.contains("UsageStatsStore"))
            #expect(!body.contains("ResourceStats"))
            #expect(!body.contains("GPUMetrics"))
            #expect(!body.contains("task_info"))
            #expect(!body.contains("host_processor"))
            #expect(!body.contains("stats.json"))
            #expect(!body.contains("resources.json"))
        }
    }

    @Test func audioTapDoesNotSampleStats() throws {
        let source = try AppSource.load("Services/AudioEngineService.swift")
        let tap = try #require(AppSource.method(source, named: "installTapLocked"))
        #expect(!tap.contains("UsageStats"))
        #expect(!tap.contains("ResourceStats"))
        #expect(!tap.contains("task_info"))
        #expect(!tap.contains("host_processor"))
        #expect(!tap.contains("JSONEncoder"))
    }

    @Test func overlayShowDoesNotTouchStats() throws {
        let source = try AppSource.load("Windows/FloatingPanelController.swift")
        let show = try #require(AppSource.method(source, named: "show"))
        #expect(!show.contains("UsageStats"))
        #expect(!show.contains("ResourceStats"))
        #expect(!show.contains("task_info"))
        #expect(!show.contains("host_processor"))
    }

    /// Reading the old clipboard can be slow when it holds an image, and it used to happen
    /// inside `paste`, i.e. between the transcript being ready and the text landing.
    @Test func clipboardIsSnapshotDuringTheTakeNotAtPaste() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let start = try #require(AppSource.method(source, named: "startRecording"))
        #expect(start.contains("PasteService.snapshotClipboard()"))

        let deliver = try #require(AppSource.method(source, named: "deliver"))
        #expect(deliver.contains("previousClipboard: pendingClipboard"))
        #expect(!deliver.contains("snapshotClipboard"))
    }

    @Test func presenceAndLibraryNeverListDirectories() throws {
        let presence = try AppSource.load("Services/Models/LocalModelPresence.swift")
        let library = try AppSource.load("Services/Models/ModelLibrary.swift")
        #expect(!presence.contains("contentsOfDirectory"))
        #expect(!library.contains("contentsOfDirectory"))
    }
}
