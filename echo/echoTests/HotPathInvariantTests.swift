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
        let tap = try #require(AppSource.method(source, named: "installTapIfNeeded"))
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

    @Test func presenceAndLibraryNeverListDirectories() throws {
        let presence = try AppSource.load("Services/Models/LocalModelPresence.swift")
        let library = try AppSource.load("Services/Models/ModelLibrary.swift")
        #expect(!presence.contains("contentsOfDirectory"))
        #expect(!library.contains("contentsOfDirectory"))
    }
}
