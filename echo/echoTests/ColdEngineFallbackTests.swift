import Testing
@testable import echo

/// A take on a cold Whisper / Parakeet must never wait out the model load after stop.
@Suite("Cold engine fallback")
struct ColdEngineFallbackTests {
    @Test func readyPrimaryAlwaysWins() {
        #expect(StopRoute.resolve(primary: .ready, fallback: nil) == .primary)
        #expect(StopRoute.resolve(primary: .ready, fallback: .ready) == .primary)
        #expect(StopRoute.resolve(primary: .ready, fallback: .pending) == .primary)
        #expect(StopRoute.resolve(primary: .ready, fallback: .failed) == .primary)
    }

    @Test func loadingPrimaryIsCoveredByReadyShadow() {
        #expect(StopRoute.resolve(primary: .pending, fallback: .ready) == .fallback)
        #expect(StopRoute.resolve(primary: .failed, fallback: .ready) == .fallback)
    }

    @Test func noUsableShadowMeansWaitOnPrimary() {
        #expect(StopRoute.resolve(primary: .pending, fallback: nil) == .primary)
        #expect(StopRoute.resolve(primary: .pending, fallback: .failed) == .primary)
        #expect(StopRoute.resolve(primary: .failed, fallback: .failed) == .primary)
    }

    @Test func bothStartingIsUndecided() {
        #expect(StopRoute.resolve(primary: .pending, fallback: .pending) == nil)
        #expect(StopRoute.resolve(primary: .failed, fallback: .pending) == nil)
    }

    @Test func stopAsksForRouteBeforeAwaitingTheLoad() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let stop = try #require(AppSource.method(source, named: "stopRecording"))
        #expect(
            AppSource.appearsInOrder(stop, [
                "transcriptionService.stopRoute()",
                "try await start?.value",
                "finishWithFallback",
                "deliver(raw)",
            ]),
            "stop must pick a route before awaiting prepare. Got:\n\(stop)"
        )
        #expect(stop.contains("Latency.stopBreakdown"))
    }

    /// The stop shortcut's modifiers are watched only during a take, and never after it ends.
    @Test func stopIntentIsWatchedOnlyWhileRecording() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let start = try #require(AppSource.method(source, named: "startRecording"))
        #expect(start.contains("stopIntent.start(modifiers: appState.hotkeyModifiers)"))
        let stop = try #require(AppSource.method(source, named: "stopRecording"))
        #expect(AppSource.appearsInOrder(stop, ["stopIntent.stop()", "stopRoute()"]))
        let quit = try #require(AppSource.method(source, named: "stop"))
        #expect(quit.contains("stopIntent.stop()"))
        let monitor = try AppSource.load("Services/StopIntentMonitor.swift")
        #expect(monitor.contains("CGEventSource.flagsState"), "no Input Monitoring permission")
        #expect(!monitor.contains("addGlobalMonitorForEvents"))
    }

    /// The shadow runs inside someone else's take: it must never prompt or download.
    @Test func shadowIsGatedOnSilentAvailability() throws {
        let service = try AppSource.load("Services/Transcription/TranscriptionService.swift")
        let start = try #require(AppSource.method(service, named: "startFallback"))
        #expect(
            AppSource.appearsInOrder(start, [
                "canServeAsFallback()",
                "shadow.startStreaming()",
            ])
        )
        let apple = try AppSource.load("Services/Transcription/AppleSTTProvider.swift")
        let gate = try #require(AppSource.method(apple, named: "canServeAsFallback"))
        #expect(gate.contains("authorizationStatus() == .authorized"))
        #expect(gate.contains("== .installed"))
        #expect(!gate.contains("requestAuthorization"))
        #expect(!gate.contains("downloadAndInstall"))
    }

    @Test func largeEnginePrewarmKeepsAppleFallbackWarm() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let prewarm = try #require(AppSource.method(source, named: "prewarm"))
        #expect(
            AppSource.appearsInOrder(prewarm, [
                "AppleSTTProvider.prewarmAsFallback()",
                "WhisperKitProvider.prewarm",
            ])
        )
        #expect(
            AppSource.appearsInOrder(prewarm, [
                "AppleSTTProvider.prewarmAsFallback()",
                "ParakeetProvider.prewarm",
            ])
        )
    }

    /// `.warning` fired every ~30 min on a 32 GB machine with a third of memory free, and each
    /// eviction cost the next take a 20–40 s reload. Only `.critical` may evict.
    @Test func onlyCriticalPressureEvicts() throws {
        let source = try AppSource.load("Services/Models/ResidentEnginePolicy.swift")
        let handle = try #require(AppSource.method(source, named: "handlePressure"))
        let critical = try #require(AppSource.firstIndex(of: ".critical", in: handle))
        let warning = try #require(AppSource.firstIndex(of: ".warning", in: handle))
        let evictions = AppSource.occurrences(of: "evictLargeGraphs()", in: handle)
        #expect(evictions.count == 1)
        for eviction in evictions {
            #expect(eviction.lowerBound > critical && eviction.lowerBound < warning)
        }
        #expect(handle.contains("prewarmAfterUse"), "return to normal must re-warm the evicted engine")
    }
}
