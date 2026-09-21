import Testing
@testable import echo

@Suite("Resident memory policy")
struct MemoryPolicyTests {
    @Test func launchPrewarmDoesNotLoadCleanupModels() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let prewarm = try #require(AppSource.method(source, named: "prewarmActiveDetached"))
        #expect(prewarm.contains("prewarm(type:"))
        #expect(!prewarm.contains("S1MiniEngine"))
        #expect(!prewarm.contains("TranscriptCleaner"))
        #expect(!prewarm.contains("cleanupEngine"))
    }

    @Test func enginePrewarmEvictsInactiveGraphs() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let prewarm = try #require(AppSource.method(source, named: "prewarm"))
        #expect(prewarm.contains("ResidentEnginePolicy.evictInactive(keeping: type)"))
        #expect(prewarm.contains("scheduleIdleUnload"))
    }

    @Test func downloadDoesNotPrewarmS1OrInactiveSTT() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let afterDownload = try #require(AppSource.method(source, named: "prewarmAfterDownload"))
        #expect(afterDownload.contains("guard type == .whisper"))
        #expect(afterDownload.contains("guard type == .parakeet"))
        #expect(!afterDownload.contains("prewarmFromPresence"))
        #expect(!afterDownload.contains("S1MiniEngine"))
    }

    @Test func startRecordingCancelsIdleUnload() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let start = try #require(AppSource.method(source, named: "startRecording"))
        #expect(start.contains("ResidentEnginePolicy.cancelIdleUnload()"))
        #expect(!start.contains("evictAllSpeech"))
    }

    @Test func s1UnloadClearsMLXCache() throws {
        let source = try AppSource.load("Services/Dictation/S1MiniEngine.swift")
        let unload = try #require(AppSource.method(source, named: "unload"))
        #expect(unload.contains("Memory.clearCache()"))
        #expect(unload.contains("container = nil"))
    }

    @Test func whisperAndParakeetEvictReleaseGraphs() throws {
        let whisper = try AppSource.load("Services/Transcription/WhisperKitProvider.swift")
        let parakeet = try AppSource.load("Services/Transcription/ParakeetProvider.swift")
        let apple = try AppSource.load("Services/Transcription/AppleSTTProvider.swift")
        let whisperEvict = try #require(AppSource.method(whisper, named: "evict"))
        let parakeetEvict = try #require(AppSource.method(parakeet, named: "evict"))
        let appleEvict = try #require(AppSource.method(apple, named: "evict"))
        #expect(whisperEvict.contains("unloadModels()"))
        #expect(parakeetEvict.contains("cleanup()"))
        #expect(appleEvict.contains("cancelAndFinishNow()"))
    }

    @Test func captureRingIsSlackNotThreeMinutes() {
        let frames = AudioSampleCollector.ringSeconds * Int(AudioResampler.targetSampleRate)
        #expect(AudioSampleCollector.ringSeconds <= 16)
        #expect(frames * MemoryLayout<Float>.size <= 1_048_576)
    }

    @Test func cleanupDropsSampleCapacity() throws {
        let source = try AppSource.load("Services/Audio/AudioSampleCollector.swift")
        let cleanup = try #require(AppSource.method(source, named: "cleanupRecordingFile"))
        #expect(cleanup.contains("removeAll(keepingCapacity: false)"))
        #expect(cleanup.contains("drainBuffer = nil"))
    }

    @Test func wordsPaneDoesNotPrewarmCleanupModels() throws {
        let settings = try AppSource.load("Views/SettingsView.swift")
        #expect(settings.contains("releaseCleanupModels()"))
        #expect(!settings.contains("TranscriptCleaner.shared.prewarm()"))
    }

    @Test func idleUnloadIsPressureDrivenWithLongBackstopAndSkipsBusyTakes() throws {
        let source = try AppSource.load("Services/Models/ResidentEnginePolicy.swift")
        #expect(source.contains("idleUnloadAfter: Duration = .seconds(2 * 60 * 60)"))
        #expect(source.contains("makeMemoryPressureSource"))
        let schedule = try #require(AppSource.method(source, named: "scheduleIdleUnload"))
        #expect(schedule.contains("startMemoryPressureWatch()"))
        #expect(schedule.contains("phase != .idle"))
        #expect(schedule.contains("evictLargeGraphs()"))
    }

    /// Apple's analyzer is tens of megabytes and reloading it is the single biggest source of a
    /// slow first take. It must survive every idle path and only go on quit.
    @Test func idleEvictionKeepsAppleSpeechResident() throws {
        let source = try AppSource.load("Services/Models/ResidentEnginePolicy.swift")
        let large = try #require(AppSource.method(source, named: "evictLargeGraphs"))
        #expect(large.contains("WhisperKitProvider.evict()"))
        #expect(large.contains("ParakeetProvider.evict()"))
        #expect(!large.contains("AppleSTTProvider.evict()"))

        let inactive = try #require(AppSource.method(source, named: "evictInactive"))
        #expect(!inactive.contains("AppleSTTProvider.evict()"))

        let everything = try #require(AppSource.method(source, named: "evictEverything"))
        #expect(everything.contains("AppleSTTProvider.evict()"))

        // Quit is the only caller allowed to drop it.
        let coordinator = try AppSource.load("EchoCoordinator.swift")
        let stop = try #require(AppSource.method(coordinator, named: "stop"))
        #expect(stop.contains("ResidentEnginePolicy.evictEverything()"))
    }

    @Test func appleAnalyzerIsBuiltWithProcessLifetimeRetention() throws {
        let source = try AppSource.load("Services/Transcription/AppleSTTProvider.swift")
        #expect(source.contains("modelRetention: .processLifetime"))
        #expect(source.contains("SpeechAnalyzer(modules: [transcriber], options: analyzerOptions)"))
    }
}
