import AVFoundation
import Testing
@testable import echo

/// Recognition must not cost more just because the take was long.
///
/// The old shape handed the whole recording to the recogniser at stop, so the wait grew with the
/// length of the dictation. These pin the pieces that make it constant instead.
@Suite("Streaming recognition")
struct StreamingRecognitionTests {

    // MARK: - Apple

    @Test func appleProviderConsumesAudioWhileRecording() throws {
        let source = try AppSource.load("Services/Transcription/AppleSTTProvider.swift")
        #expect(source.contains("StreamingAudioConsumer"))
        #expect(source.contains("analyzer.start(inputSequence: stream)"))
        #expect(source.contains("finalizeAndFinishThroughEndOfInput()"))
    }

    /// The microphone is live before the analyzer is, so early audio has to be queued.
    /// Without this the first words of every take go missing from the streamed transcript.
    @Test func appleQueuesAudioCapturedBeforeAnalyzerIsReady() throws {
        let source = try AppSource.load("Services/Transcription/AppleSTTProvider.swift")
        let consume = try #require(AppSource.method(source, named: "consumeStreamingBuffer"))
        #expect(consume.contains("pendingBuffers.append(buffer)"))

        let begin = try #require(AppSource.method(source, named: "beginLiveInput"))
        #expect(
            AppSource.appearsInOrder(begin, [
                "streaming = true",
                "pendingBuffers = []",
                "analyzer.start(inputSequence: stream)",
            ]),
            "beginLiveInput must go live and flush the backlog before awaiting start. Got:\n\(begin)"
        )
    }

    @Test func drainedHandlerIsHookedBeforeStartStreaming() throws {
        let source = try AppSource.load("Services/Transcription/TranscriptionService.swift")
        let prepare = try #require(AppSource.method(source, named: "prepare"))
        #expect(
            AppSource.appearsInOrder(prepare, [
                "setDrainedHandler",
                "provider.startStreaming()",
            ]),
            "Audio must be routed to the provider before it starts, or early audio is lost."
        )
    }

    /// The legacy recogniser is a last resort. It used to be able to add 2.5 s to a take that had
    /// already been transcribed successfully.
    @Test func legacyFallbackIsTightlyBounded() throws {
        let source = try AppSource.load("Services/Transcription/AppleSTTProvider.swift")
        #expect(source.contains("timeout: Double = 1.5"))
        #expect(!source.contains("now() + 2.5"))
    }

    // MARK: - Chunk pipeline

    @Test func cutPointLandsInTheQuietestPartOfTheWindow() {
        let rate = Int(AudioResampler.targetSampleRate)
        var samples = [Float](repeating: 0.5, count: rate * 3)
        // A clear 200 ms silence 500 ms before the nominal boundary.
        let gapStart = rate * 3 - rate / 2 - rate / 5
        for index in gapStart..<(gapStart + rate / 5) {
            samples[index] = 0
        }

        let cut = AudioChunkPipeline.cutPoint(
            in: samples,
            preferred: samples.count,
            searchBack: rate * 3 / 2
        )

        #expect(cut >= gapStart)
        #expect(cut <= gapStart + rate / 5)
    }

    @Test func cutPointFallsBackToTheBoundaryWhenAudioIsTooShort() {
        let samples = [Float](repeating: 0.3, count: 128)
        let cut = AudioChunkPipeline.cutPoint(in: samples, preferred: 128, searchBack: 64)
        #expect(cut == 128)
    }

    @Test func pipelineJoinsWindowsInOrder() async throws {
        let rate = Int(AudioResampler.targetSampleRate)
        let order = Counter()
        let pipeline = AudioChunkPipeline(windowSeconds: 1, boundarySearchSeconds: 0.05) { chunk, _ in
            _ = chunk
            return "w\(order.next())"
        }

        // Four seconds of audio in quarter-second appends.
        for _ in 0..<16 {
            pipeline.append([Float](repeating: 0.2, count: rate / 4))
        }
        let text = try await pipeline.finish()

        let words = text.split(separator: " ").map(String.init)
        #expect(words == words.sorted { lhs, rhs in
            (Int(lhs.dropFirst()) ?? 0) < (Int(rhs.dropFirst()) ?? 0)
        })
        #expect(words.count >= 4)
    }

    @Test func pipelineReportsFailureSoTheCallerCanRetranscribe() async {
        let rate = Int(AudioResampler.targetSampleRate)
        let pipeline = AudioChunkPipeline(windowSeconds: 1, boundarySearchSeconds: 0.05) { _, _ in
            throw ChunkPipelineFailure()
        }
        for _ in 0..<8 {
            pipeline.append([Float](repeating: 0.2, count: rate / 4))
        }

        await #expect(throws: (any Error).self) {
            try await pipeline.finish()
        }
    }

    @Test func whisperFallsBackToTheWholeTakeOnChunkFailure() throws {
        let source = try AppSource.load("Services/Transcription/WhisperKitProvider.swift")
        let stop = try #require(AppSource.method(source, named: "stopStreaming"))
        #expect(stop.contains("pipeline.finish()"), "should try the streamed text first")
        #expect(
            stop.contains("retranscribing the whole take"),
            "must fall back to the full buffer if a window failed"
        )
        #expect(
            stop.contains("sawAtLeast(frames: capturedFrames)"),
            "must not paste a streamed transcript that missed part of the take"
        )
    }

    /// Whisper's model window is genuinely independent per 30 s, so cutting a take into windows
    /// matches how it already works. Parakeet is not: FluidAudio resets the TDT decoder state for
    /// every chunk and stitches them with overlapping context frames, so hand-cut windows with a
    /// threaded state would be using the library against its own contract. It stays whole-take.
    @Test func parakeetDeliberatelyDoesNotChunk() throws {
        let source = try AppSource.load("Services/Transcription/ParakeetProvider.swift")
        #expect(!source.contains("AudioChunkPipeline"))
        #expect(!source.contains("StreamingAudioConsumer"))
        #expect(source.contains("resets the TDT decoder state"))
    }

    /// A tail too short for the recogniser must not throw away windows already transcribed.
    @Test func tailFailureKeepsCompletedWindows() throws {
        let source = try AppSource.load("Services/Transcription/AudioChunkPipeline.swift")
        let finish = try #require(AppSource.method(source, named: "finish"))
        #expect(finish.contains("minimumTailFrames"))
        #expect(finish.contains("keeping the"))
    }

    @Test func pipelineKeepsWindowsWhenOnlyTheTailIsUnusable() async throws {
        let rate = Int(AudioResampler.targetSampleRate)
        let pipeline = AudioChunkPipeline(windowSeconds: 1, boundarySearchSeconds: 0.05) { chunk, isFinal in
            // Stand in for a recogniser that rejects very short audio.
            if isFinal || chunk.count < rate / 2 { throw ChunkPipelineFailure() }
            return "window"
        }
        for _ in 0..<10 {
            pipeline.append([Float](repeating: 0.2, count: rate / 4))
        }
        let text = try await pipeline.finish()
        #expect(text.contains("window"), "completed windows must survive a failing tail")
    }
}

/// Test-only monotonic counter. The pipeline serialises its calls, so a plain lock is enough.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// The overlay wave has to be visible on whatever the user happens to have on screen.
@Suite("Overlay wave contrast")
struct OverlayWaveContrastTests {
    /// Regression: this defaulted to `true` and nothing ever assigned it, so the wave was drawn
    /// white on the light glass plate and was invisible on a white page.
    @Test func waveDefaultsToDarkInkForTheLightGlassPlate() throws {
        let source = try AppSource.load("Views/OverlayChipView.swift")
        #expect(source.contains("var backdropIsDark = false"))
        #expect(source.contains("NSAppearance(named: .aqua)"))
    }

    @Test func overlayActuallySetsTheWaveTone() throws {
        let source = try AppSource.load("Windows/FloatingPanelController.swift")
        let show = try #require(AppSource.method(source, named: "show"))
        #expect(show.contains("applyBackdropTone()"))
        let apply = try #require(AppSource.method(source, named: "applyBackdropTone"))
        #expect(apply.contains("chipView?.backdropIsDark"))
        #expect(apply.contains("effectiveAppearance"))
    }

    /// Both tones keep a halo in the opposite tone, which is what makes a mismatch survivable.
    @Test func bothTonesKeepAContrastingHalo() throws {
        let source = try AppSource.load("Views/OverlayChipView.swift")
        let draw = try #require(AppSource.method(source, named: "draw"))
        #expect(draw.contains("NSColor.white.withAlphaComponent(0.96)"))
        #expect(draw.contains("NSColor.black.withAlphaComponent(0.78)"))
        #expect(draw.contains("setShadow"))
    }
}
