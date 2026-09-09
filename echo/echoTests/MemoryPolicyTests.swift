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

    @Test func idleUnloadIsTenMinutesAndSkipsBusyTakes() throws {
        let source = try AppSource.load("Services/Models/ResidentEnginePolicy.swift")
        #expect(source.contains("idleUnloadAfter: Duration = .seconds(10 * 60)"))
        let schedule = try #require(AppSource.method(source, named: "scheduleIdleUnload"))
        #expect(schedule.contains("phase != .idle"))
        #expect(schedule.contains("evictAllSpeech()"))
    }
}
