# Plan: constant-time Parakeet stop (item 3) and a "fastest" engine tier (item 5)

Paths: Echo sources are under `/Users/fuadnafiz98/Developer/vibes/echo/echo/echo/`; `$FA` = `/Users/fuadnafiz98/Library/Developer/Xcode/DerivedData/echo-acvewkjgnstevhgyomabrxyhmtzi/SourcePackages/checkouts/FluidAudio` (v0.15.5, commit 19600a48).

## 1. Feasibility and latency budget

### 1.1 What the measured 170 ms floor actually is

Facts established from code and logs:

- The TDT encoder on disk is a **fixed-shape** CoreML program: `Encoder.mlmodelc/metadata.json` in `~/Library/Application Support/Echo/Models/parakeet/parakeet-tdt-0.6b-v2/` declares input `mel [1, 128, 1501]` (exactly 15 s at a 10 ms hop), output `[1, 1024, 188]`, `hasShapeFlexibility: 0`. FluidAudio always pads to `ASRConstants.maxModelSamples = 240_000` (`$FA/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrManager+Transcription.swift:17`). The Preprocessor is flexible-shape but is fed the padded buffer anyway. Consequence: **the encoder pass costs the same for 0.3 s and 15 s of audio, and it cannot be made cheaper without re-exporting the model.**
- FluidAudio's own profile (`$FA/Documentation/ASR/EncoderComputePlacement.md`, `$FA/Documentation/ANE_Profiler.md:44-55`): one 15 s encoder pass is **23.5 ms on ANE / 17.8 ms on GPU** on an M-series Mac (28 ms on the profiled machine); preprocessor ~1–3 ms; decoder LSTM ~0.1–0.23 ms per call and joint ~0.22–0.46 ms per call, both CPU dispatch-bound, ~40 + ~49 calls per 7.8 s of speech. So the **linear** part of Echo's fit is the decode loop, and the constant part is encoder + preprocessor + CoreML dispatch overhead + Echo's own flush/hops.
- Echo's log on this M1 Pro: `model warmup parakeet.v2 111.6ms` for a 0.3 s padded clip (this is the whole FluidAudio pipeline with almost no tokens; a lower bound for any window, possibly inflated by first-call effects), `stop breakdown flush=10.8ms waitEngine=0.0ms decode=189.2ms` for 20.5 s. Fitting only the ≤15 s single-window takes (192 @ 4.9 s, 209 @ 5.7 s, 209 @ 6.8 s, 244 @ 10.7 s) gives roughly **decode ≈ 110 ms + ~9–12 ms per second of speech in the window**. The 4.4 ms/s slope you fitted across all takes is flatter only because >15 s takes run 4 chunks in parallel (`ASRConfig.parallelChunkConcurrency = 4`).

### 1.2 Budget per approach (M1 Pro, warm model, stop → text on clipboard)

| Stage | Today (whole take at stop) | Item 3: pause-aligned windows | Item 3 + speculative tail (stop after a pause) | Nemotron-1120 / EOU-320 (item 5) |
|---|---|---|---|---|
| Capture flush (`endCapture`: ring drain + `AudioDeviceStop`) | ~11 ms (measured) | ~11 ms | ~11 ms | ~11 ms |
| Model-side constant (preproc + one encoder pass + dispatch) | ~110 ms | ~110 ms (final window only) | **0** (tail already decoded) | one small cache-aware chunk: ~15–40 ms |
| Decode loop | ~9–12 ms × take seconds (÷4 above 15 s) | ~9–12 ms × **tail** seconds (tail ≤ 8–12 s, avg ~4 s) | 0 | ~10–30 ms (RNNT over ≤ 14 frames) |
| Merge / join / tokens→text | ~1 ms | ~1 ms | ~1 ms | ~1–10 ms (tokenizer decode of all ids; O(n)) |
| `DictationCleanup.apply` + `PasteService.paste` | ~3–5 ms warm (47 ms observed on the first take after launch) | same | same | same |
| **Total, 5 s take** | ~192 ms (measured) | ~170–190 ms | **~30–60 ms** | ~50–90 ms |
| **Total, 10 min take** | ~2.8 s (extrapolated) | ~170–250 ms | ~30–60 ms | ~50–90 ms |
| **Total, 1 h take** | ~16 s | ~170–250 ms | ~30–60 ms | ~50–100 ms |

What is achievable, stated plainly:

- **~200 ms tier, any length: yes**, with TDT 0.6B v2 as-is, by decoding windows while the user talks and leaving only a short tail (≤ ~8 s) for the stop. The tail length is the lever: decode ≈ 110 + ~10 ms/s of tail, so shorter windows buy a shorter stop.
- **~100 ms tier with TDT: only conditionally.** Any tail that contains fresh speech pays the ~110 ms constant (encoder + preprocessor + dispatch) on this M1 Pro; you cannot go below ~130 ms stop→paste when the last second of audio is speech. But dictation stops almost always come 0.5–2 s *after* the last word. If the tail up to the last pause is decoded speculatively when the pause is detected, the stop path has nothing to decode and lands at **~30–60 ms**. Misses fall back to the ~200 ms tier. This is the cheapest route to "instant" and it keeps TDT accuracy.
- **~100 ms tier unconditionally** requires a cache-aware streaming model (Nemotron 0.6B or Parakeet EOU 120M), i.e. item 5, at the cost of a new ~225–626 MB download, English-only, and (for EOU) 2–3.5x the word errors.
- Possible ~20% shave of the constant: `AsrModels.load(..., encoderComputeUnits: .cpuAndGPU)` (17.8 vs 23.5 ms per pass in FluidAudio's measurement; WER-neutral). One-line experiment; GPU is shared with the Metal globe overlay, so measure.

## 2. Item 3 — approaches compared

Reference points in FluidAudio that drive this comparison:

- Batch (what Echo runs today for >15 s): `ChunkProcessor` decodes each ~14.9 s chunk with a **fresh** decoder state (`$FA/.../TDT/ChunkProcessor.swift:499-501`), 2 s overlap, then merges tokens by timestamp LCS (`mergeChunks`, lines 846-945) with splice-safety and case-variant collapse (issues #683/#706). Every take over 15 s already has seams every 12.9 s; the accuracy the user accepts today includes them.
- `SlidingWindowAsrManager` (`$FA/.../SlidingWindow/SlidingWindowAsrManager.swift`) instead carries **one decoder state across windows** (`transcribeChunk(... decoderState: &state, previousTokens: accumulatedTokens ...)`, lines 443-449) and removes overlap duplicates with `removeDuplicateTokenSequence` (`AsrManager+TokenProcessing.swift:104-107`, whose own comment says "Ideally this is not needed ... this should be a temporary workaround"). The overlap skip is only exact when `timeJump == 0`: `TdtFrameNavigation.calculateInitialTimeIndices` (`$FA/.../TDT/Decoder/TdtFrameNavigation.swift:33-46`) returns `standardOverlapFrames` (25) when `timeJump == 0`, but returns `timeJump` itself (e.g. 2) otherwise, so ~1.8 s of already-decoded audio is re-decoded and dedup must catch it (max 12-token suffix/prefix match, then a bounded substring search). FluidAudio has a regression suite for exactly this (`$FA/Tests/FluidAudioTests/ASR/TokenDeduplicationRegressionTests.swift`). This is the concern the `ParakeetProvider.swift:5-11` header states, and the code confirms it is real.

| | (a) `SlidingWindowAsrManager` | (b) Pause-segmented independent utterances (plain cut, no context) | (c) Incremental tail re-decode with stable-prefix commit | (e) **Recommended: pause-aligned context windows, fresh state, time-trimmed** |
|---|---|---|---|---|
| Mechanism | 11 s chunk + 2 s L/R context, shared decoder state, token dedup | Cut at ≥N ms pauses (≤15 s cap), each segment `transcribe()` fresh, join with space | Re-decode last ≤15 s on every ~1 s of new audio; commit text older than X s | Cut at pauses; decode `[cut_k−1 − L, cut_k + R]` (L≈1.5 s, R≈1 s) with **fresh state** via public `transcribe()`; keep only tokens whose absolute start ∈ [cut_k−1, cut_k) using `ASRResult.tokenTimings` |
| Seam accuracy | Medium risk: dedup heuristic; false-sentence-start capitalization (#706) when dedup misses; FluidAudio labels dedup a workaround | **Systematic punctuation artifact**: TDT v2 emits sentence-final "." at end-of-audio and capitalizes the first word of every segment (SOS-primed), so mid-sentence pauses become sentence breaks | Same as batch inside 15 s, but the commit boundary is a hard cut in the decoder's history → same SOS/period problem as (b) unless overlapped | Low: cut lies inside a ≥240 ms pause so no token straddles it (TDT emission delay is 1 frame = 80 ms); window k sees R s past the cut so it does not emit end-of-audio punctuation; window k+1 sees L s before the cut so the first kept word has acoustic + LM context. Fresh state per window is what batch does too |
| Stop latency | One `flushRemaining` window: left 2 s + ≤11 s tail → ~110 + ~10×(≤13) ≈ 150–240 ms, plus waiting for any in-flight window | ~110 + ~10×tail | Constant but every re-decode is a full window; at stop still one window | ~110 + ~10×tail (tail ≤ 8 s by choosing ~7–8 s windows); **~0 with speculative tail** |
| Load while talking | 1 window per 11 s ≈ 2% ANE/CPU duty | 1 per ~12 s | **1 window per second ≈ 15–25% duty** — wasteful, thermal | 1 per ~8 s ≈ 2.5%; speculative adds ≤1 per pause |
| Memory, hours | flat (buffer trimmed; token array grows linearly, small) | flat | flat | flat (pending ≤15 s + strings) |
| Complexity | Low wiring; new manager per take (`inputSequence` created in `init`, not reusable after `finish()`); need `AsrModels` in Echo's cache to call `loadModels(_:)` | Low (AudioChunkPipeline reuse) | Medium | Medium: new pipeline class (~250 lines) with pause finder, window planner, token trimmer, speculative cache |
| Failure modes | Silent word drop/dup at seams; `finish()` throws only if *all* windows failed | Period/capital artifacts every seam; forced mid-word cut if no pause in the cap | CPU heat; commit-boundary artifacts | Forced cut when no pause found in 5.5 s search (log + tolerate; text join without separator handles identical segmentation); FluidAudio throws for <0.3 s windows (pad like `AudioChunkPipeline.finish`) |
| Vocabulary boosting | Built-in hook (`configureVocabularyBoosting`), needs CTC 110M download | none (Echo does not use FluidAudio vocab for Parakeet today) | none | none today; window decodes happen off the stop path, so CTC rescoring per window would be free latency-wise later |

Anything else in FluidAudio? `StreamingUnifiedAsrManager`, `StreamingNemotronAsrManager`, `StreamingEouAsrManager` are different models (item 5), not applicable to TDT v2. `ChunkProcessor`'s v3-only `silenceAlignedChunkStarts` is the same idea as (e) but internal and v3-only.

**Recommendation: (e)**, with (a) wired behind a flag as the A/B comparator (it is ~80 lines to wire and gives an independent accuracy baseline), and whole-take batch as the fallback exactly as `WhisperKitProvider.stopStreaming` does. Reasons: it reuses only public FluidAudio API (`AsrManager.transcribe(_:decoderState:)`, `ASRResult.tokenTimings`), it mirrors the fresh-state-per-chunk design of the batch path the user already trusts, it avoids the dedup heuristic, it is directly testable against batch on the same audio, and it is the only variant that naturally extends to the speculative tail that reaches the ~100 ms tier without a new model.

## 3. Detailed design (item 3)

### 3.1 New and changed types

`/Users/fuadnafiz98/Developer/vibes/echo/echo/echo/Services/Transcription/PauseAlignedWindowPipeline.swift` (new, `nonisolated final class ... @unchecked Sendable`, lock + chained Tasks exactly like `AudioChunkPipeline`; the project has `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_STRICT_CONCURRENCY = targeted` in `echo/echo.xcodeproj/project.pbxproj:383-386`, so mark every new type `nonisolated` as the existing ones do):

- `struct Layout: Sendable { leftSeconds = 1.5, rightSeconds = 1.0, targetChunkSeconds = 7.0, searchUntilSeconds = 9.5, hardCapSeconds = 12.4 }` with an invariant `left + hardCap + right ≤ 14.9` (checked by a pure test; the 15 s encoder cap is `ASRConstants.maxModelSamples`).
- `struct Window: Sendable { start, end: Int /* absolute sample indices of kept range */, contextStart, contextEnd: Int, isFinal: Bool, forced: Bool }`.
- `typealias Decode = @Sendable ([Float], Double /* seconds offset of the window's first sample */) async throws -> [TokenTiming]` — the provider supplies this; the pipeline owns trimming and joining.
- `func append(_ samples: [Float])` (IO queue; never awaits): appends to `pending`, updates `totalFrames`, runs the pause scanner incrementally (20 ms RMS frames, same vDSP as `AudioChunkPipeline.cutPoint`), and when a cut is chosen *and* `pending` extends ≥ R past it, enqueues a window decode; also feeds the speculative logic (3.4).
- `func finish() async throws -> String`: marks finished, waits for the chain, decodes the final window `[lastCut − L, end]` (no R), or uses the speculative result if valid, joins kept token strings, throws `ChunkPipelineFailure` if any non-final window failed (caller then batch-decodes the whole take).
- `func cancel()`, `var didFail`, `var frameCount`, `func sawAtLeast(frames:)` — same contract as `AudioChunkPipeline` so `ParakeetProvider.stopStreaming` can be a near-copy of `WhisperKitProvider.stopStreaming` (`WhisperKitProvider.swift:174-241`).
- Static, pure, unit-testable helpers: `choosePause(in: pending, notBefore:, preferUntil:, hardCap:) -> (index, forced)`, `trim(tokens: [TokenTiming], windowOffsetSeconds:, keep: Range<Double>) -> [TokenTiming]` (with the punctuation attach rule: a punctuation-only token starting within 2 frames after the cut belongs to the earlier window unless it already ends with punctuation), `join(pieces: [[TokenTiming]]) -> String` (concatenate `TokenTiming.token` strings — they carry the leading space for word-initial pieces via `normalizedTimingToken` — so a forced mid-word cut joins without an inserted space).

`ParakeetProvider.swift` changes:

- Adopt `StreamingAudioConsumer` (keep `BatchAudioConsumer`). `consumeStreamingBuffer` → `pipeline?.append(AudioResampler.floats(from: buffer))` (same as `WhisperKitProvider.swift:163-168`).
- `startStreaming()`: read policy; if streaming is on, install the pipeline **before** awaiting `loadCached` (the comment in `WhisperKitProvider.swift:127-131` explains why: early audio must not be dropped during a cold load; `TranscriptionService.prepare` already hooks the drained handler before `startStreaming`, `TranscriptionService.swift:97-103`). The decode closure: `let loaded = try await Self.loadCached(...)`; `var state = TdtDecoderState.make(decoderLayers: loaded.decoderLayers)`; `let result = try await loaded.manager.transcribe(samples, decoderState: &state)`; return `result.tokenTimings ?? []`, shifted by the window offset.
- `stopStreaming()`: fast path `pipeline.finish()` guarded by `frameCount > 0 && sawAtLeast(frames: capturedFrames)`; on `ChunkPipelineFailure` or partial coverage, `Latency.note(...)` and fall through to today's `resolvedSamples()` batch code (kept verbatim). `cancelStreaming()` → `pipeline?.cancel()`.
- `CachedManager` gains `models: AsrModels` so the (a) comparator can call `SlidingWindowAsrManager.loadModels(_ models:)` sharing the same `MLModel` instances (no extra memory).
- Log per window: `Latency.parakeetWindow(seconds:, decodeMs:, forced:, speculative:)` (new in `Latency.swift`), and extend `Latency.stopBreakdown` with `tailSeconds` and `speculativeHit`.

### 3.2 Threading

Collector IO queue → `append()` (lock-protected, allocation-light, no awaits) → `Task(priority: .userInitiated)` chained on `previous` exactly as `AudioChunkPipeline.enqueueLocked` (`AudioChunkPipeline.swift:177-202`) so decodes are serialized (one ANE/CPU job at a time, in order). Intermediate windows could run at `.utility` to avoid competing with the UI; the final window and any window still queued at stop must be `.userInitiated` (the user is waiting). Since priority is fixed at Task creation, keep `.userInitiated` for all (each is ~200 ms every ~8 s) — measure UI impact with the globe overlay.

### 3.3 Backpressure

Windows cost ~200 ms per ~8 s of audio, so falling behind real time is not expected. Guard anyway: track `queuedWindows`; if at stop the backlog is ≥ 4 windows (≥ 30 s undecoded), `cancel()` the chain and take the whole-take batch path (its 4-way parallel `ChunkProcessor` decodes 30 s in ~300 ms) rather than serially draining. Never drop audio; the collector's RAM/CAF copy is always complete.

### 3.4 Speculative tail (Phase 2; the ~100 ms tier for TDT)

- A live pause detector on `append()`: when ≥ 300 ms of frames are below the adaptive threshold after ≥ 0.5 s of speech since the last cut, enqueue a *speculative* decode of `[lastCut − L, pauseStart + 0.15 s]` (no R; audio "ends" there, so the model finalizes exactly as it would at a real stop). Store `Speculative(tailEnd: Int, tokens: [TokenTiming], generation)`.
- Invalidate when any later 20 ms frame exceeds the speech threshold; cancel a still-running speculative Task when a newer pause supersedes it (FluidAudio checks `Task.checkCancellation()` in the decode loop). Rate-limit to one speculative decode per 3 s so a hesitant speaker does not burn ANE.
- At `finish()`: if a valid speculative result exists and every frame after `tailEnd` is silent → join and return with **no decode**. Otherwise decode normally. If the speculative Task is still running at stop, await it (same cost as decoding at stop; no regression).
- Expected hit rate on real dictation is high because the hotkey is pressed after the sentence ends; measure (`speculativeHit=true|false` in the breakdown line).

### 3.5 Interactions

- **Apple shadow / `StopRoute`**: unchanged. `TranscriptionService.prepare` routes drained buffers to both the streamer and the shadow when cold (`TranscriptionService.swift:97-103`), re-routes to the streamer alone once `markPrimary(.ready)` fires (lines 265-281), and `finishWithFallback` cancels the primary (`cancelStreaming()` → `pipeline.cancel()`). The only Parakeet-specific line, `isCold` (line 322-323), stays. During a cold take the pipeline buffers audio in `pending` until the model loads, then the chain decodes several windows back to back (~1 s) — acceptable and only on cold takes.
- **`ResidentEnginePolicy`**: no change; eviction is gated on `phase == .idle` (`ResidentEnginePolicy.swift:56-60`, 136-139). If the manager was evicted between takes, the first window's closure re-runs `loadCached` (same as Whisper).
- **Vocabulary**: Echo does not pass hints to Parakeet today (`TranscriptionService.applyHints`, lines 330-337); vocabulary is handled by `DictationCleanup`. Leave as is. Note for later: because window decodes are off the stop path, FluidAudio's CTC rescoring (`configureVocabularyBoosting`, needs `parakeet-ctc-110m-coreml` ~100 MB) could be run per window with zero stop-latency cost, except on the tail.
- **Hour-long takes**: pipeline memory is flat; the collector still spills to CAF after 90 s (`AudioSampleCollector.swift:49, 324-333`) purely as the batch fallback source; `resolvedSamples()` (`AudioSampleCollector.swift:24-28`) is now read only on fallback.
- **Cancellation**: `cancel()` cancels every queued Task (`queued` array pattern from `AudioChunkPipeline.swift:29-30, 147-160`).

### 3.6 Flags (UserDefaults, `com.fuadnafiz98.echo`)

- `echo.parakeetStreaming` = `"off"` (default until Phase 3) | `"windows"` | `"speculative"` | `"slidingWindow"` (FluidAudio manager, A/B only).
- `echo.parakeetWindowSeconds` (Double, debug override of `targetChunkSeconds`).
- `echo.parakeetEncoderGPU` (Bool) → `encoderComputeUnits: .cpuAndGPU` at `ParakeetProvider.swift:188`.
- `echo.debugCaptureTakes` (Bool) → opt-in corpus capture (4.1).
Same pattern as `AppleSTTProvider.forceBatchPath` (`AppleSTTProvider.swift:15-19`).

## 4. Accuracy validation before flipping the default

### 4.1 Corpus

Echo retains no audio: RAM samples are dropped and the CAF deleted in `cleanupRecordingFile` (`AudioSampleCollector.swift:249-282`); `UsageStats` stores only word counts and timings. Add an opt-in **debug capture**: when `echo.debugCaptureTakes` is on, after `deliver` a `Task.detached(priority: .utility)` writes `AudioResampler.wavData(from: snapshot.resolvedSamples())` plus a JSON sidecar (batch transcript, streamed transcript, cut indices, forced-cut flags, timings) to `~/Library/Application Support/Echo/DebugTakes/<ISO date>.{wav,json}`. Expose it as a native `Toggle("Keep recordings for accuracy testing")` in the General pane with a footer explaining that audio stays on this Mac. Never on the stop path (`HotPathInvariantTests.deliverDoesNotPersistStatsOrSampleProcess` forbids `write(to:` in `deliver`; do it in a separate method called after `deliver`).

Target: 40–60 real takes over a week (5 s to 5 min, including fast speech and code-ish vocabulary), plus 3 long reads (10, 20, 30 min) and the `say`-synthesized fixtures already used by `AppleStreamingLatencyTests`. Hand-correct 10–15 takes for absolute WER; use the whole-take batch transcript as the reference for the rest (the goal is parity, not beating batch).

### 4.2 Harness (echoTests, disabled unless `ECHO_PARAKEET_TESTS=1`, `.serialized`, run in Release)

`ParakeetStreamingParityTests`: for each WAV, run (1) batch via `ParakeetProvider` with streaming off, (2) `"windows"`, (3) `"speculative"`, (4) `"slidingWindow"`; feed 4096-frame buffers through `consumeStreamingBuffer` (faster than real time is fine for parity). Report per take: normalized WER vs reference (port `calculateWer` from `$FA/Sources/FluidAudioCLI/Commands/ASR/Parakeet/Streaming/ParakeetEouCommand.swift:466-509`), punctuation-inclusive CER, number of cuts, forced cuts, and **seam diagnostics**: for every cut, the words within ±1 s compared to batch (insertions/deletions), glued words (token without leading space following a word-final token across a seam), capitalization flips, punctuation inserted at the seam. Emit one `Latency.note("PARITY ...")` line per take so results are readable with `log show`, as the Apple test does.

`ParakeetStreamingLatencyTests`: same shape as `AppleStreamingLatencyTests` (`echoTests/AppleStreamingLatencyTests.swift:78-116`): real-time feed of 5 s / 60 s / 10 min synthesized audio, measure `stopStreaming()` tail; add one case that ends 1.5 s after the last word (speculative hit) and one that ends mid-word (miss). Fit tail vs length; assert slope.

Optional external baseline: `swift run -c release fluidaudiocli asr-benchmark --model-version v2 --max-files 200` from `$FA` gives this machine's LibriSpeech WER for v2 (FluidAudio's harness reports 2.6% for v3).

### 4.3 Acceptance to flip the default

- Aggregate WER (windows vs batch reference) ≤ +0.3 pp absolute over the corpus; no single take worse than +2 pp; zero glued words; seam punctuation insertions ≤ 1 per 10 seams; forced cuts ≤ 5% of cuts on real takes.
- Latency: tail p50 ≤ 220 ms and p95 ≤ 300 ms from 5 s to 10 min, slope ≤ 0.2 ms per audio second; speculative hits p50 ≤ 70 ms stop→paste with ≥ 50% hit rate on real takes.

## 5. Item 5 — a "fastest" engine tier

### 5.1 Candidates, measured facts (FluidAudio docs, HF API sizes)

| Engine (FluidAudio manager) | Chunk / hop | Model-side work at `finish()` | WER LibriSpeech test-clean | While-talking load (estimate for M1 Pro) | Download (required `.mlmodelc` only) | PnC |
|---|---|---|---|---|---|---|
| Parakeet EOU 120M, 160 ms (`StreamingEouAsrManager`) | 2560 samples, hop 1280 (80 ms!) | pad remaining to one chunk, 1 encoder pass (~6.5 ms on M-series) + ≤2 RNNT frames | 8.23% avg | ~8 ms per 80 ms hop ≈ 10% duty | ~224 MB (encoder 213 + decoder 7.9 + joint 2.8 + vocab) | verify |
| Parakeet EOU 120M, 320 ms | 10080 samples, hop 5120 | same, one chunk | 4.88% avg | ~3–4% duty | ~224 MB | verify |
| Nemotron 0.6B EN, 1120 ms (`StreamingNemotronAsrManager`) | 1.12 s | pad to one chunk: int8 encoder ~13 ms (M5 Pro; ~30 ms M1 Pro guess) + RNNT over 14 frames (~0.3–0.5 ms/step) | 2.28–2.58% agg. | ~3–4% duty | ~626 MB | verify |
| Nemotron 0.6B EN, 560 ms | 0.56 s | same, smaller chunk | 2.28–2.71% | ~6–8% duty | ~626 MB | verify; punctuation thins on small chunks (#687) |
| Parakeet Unified 0.6B, 640 ms `[70,7,1]` (`StreamingUnifiedAsrManager`) | re-encodes a 6.24 s window per 0.56 s | exactly one more window pass (`UnifiedStreamingWindower` final flush, holdback 0) | 2.40% | RTFx 27x ⇒ ~4% duty | encoder int8 563 MB + decoder + joint (~14 + 3 MB; verify) | **yes** |
| Parakeet Unified 320 ms `[70,2,2]` | re-encodes per 0.16 s | one pass | 2.37% | RTFx 10x ⇒ ~10% duty | same | yes |
| Apple SpeechAnalyzer (already implemented) | streaming | `finalizeAndFinishThroughEndOfInput` | n/a | low | 0 | yes |
| TDT v2 + item 3 speculative | — | 0 on hit, ~110+10×tail ms on miss | ≈ batch TDT (~2–2.6%) | ~2.5% + speculative | 0 (already installed) | yes |

Honest verdicts:

- **EOU 160 ms is not worth shipping** for dictation: 8.2% WER is ~3.5x TDT's errors, and it costs the most compute per second of audio.
- **EOU 320 ms** is the fastest credible option (~50 ms stop→paste) but ~2x TDT's errors. Only attractive if the user values speed over accuracy for short commands.
- **Nemotron 1120 ms** gives TDT-class accuracy with a ~60–90 ms stop and low duty; English-only, 626 MB. This is the strongest "always ~100 ms" candidate.
- **Unified 640 ms** is the best accuracy-per-latency of the true streamers and has PnC, but re-encoding a 6 s window every 0.56 s is heavier than Nemotron; measure both.
- **Apple streaming** is not a ~100 ms tier: the doc comments in `AppleStreamingLatencyTests.swift:38-44` record 135 / 489 / 443 ms tails (4 s / 67 s / 202 s, Debug). Measure it properly with `ECHO_LATENCY_TESTS=1 xcodebuild test -only-testing:echoTests/AppleStreamingLatencyTests -configuration Release …` and read the `LATENCY` lines from `log show`; also log `stopBreakdown` for `provider=apple` takes. It stays the cold-engine safety net.
- **Decide item 5 after Phase 2.** If speculative TDT hits ≥ 60% of real stops, a second engine buys little; if the user often stops mid-flow (misses), Nemotron-1120 is the engine to add.

### 5.2 How a streaming FluidAudio engine maps into Echo

- Catalog: extend `ParakeetVariant` (`LocalModelCatalog.swift:86-107`) with cases carrying a backend: `.v2English`, `.v3Multilingual` (TDT), `.eou320`, `.nemotron1120` (streaming), plus `var backend: ParakeetBackend { .tdt | .streaming(StreamingModelVariant) }`, `displayName` ("Parakeet EOU 120M (fast)", "Nemotron 0.6B Streaming"), `sizeLabel` ("~225 MB", "~630 MB"), `detail`. Keeping the `.parakeet` provider type means `AppState.canSelect/selectEngine/useParakeet/repairEngineIfNeeded`, `ModelsSettingsPane`'s Parakeet section (`SettingsView.swift:403-414`, native `LabeledContent`/`Button`/`ProgressView`), and `ResidentEnginePolicy.evictInactive` need no structural change.
- Paths/presence: `LocalModelPaths.parakeetRepoFolderName` (`LocalModelPaths.swift:77-83`) returns `Repo.folderName` (`parakeet-eou-streaming/320ms`, `nemotron-streaming/1120ms`, from `$FA/Sources/FluidAudio/ModelNames.swift`); `LocalModelPresence.probe` (`LocalModelPresence.swift:94-104`) branches on backend: TDT → `AsrModels.modelsExist`, streaming → `ModelNames.ParakeetEOU.requiredModels` / `encoder/encoder_int8.mlmodelc` + `tokenizer.json` exist (known paths, no directory walk — `presenceAndLibraryNeverListDirectories` test).
- Download: `LocalModelIO.downloadParakeet` (`LocalModelIO.swift:137-162`) → for streaming backends `try await ModelHub.download(repo, to: LocalModelPaths.parakeetDirectory(), progressHandler:)` (`$FA/Sources/FluidAudio/Shared/Download/ModelHub.swift:205`), which lands in `parakeetDirectory/<repo.folderName>` and fetches only the required `.mlmodelc` bundles. Delete URLs via `parakeetDeleteURLs`.
- Provider: new `FluidStreamingProvider` (`TranscriptionProvider`, `StreamingAudioConsumer`, `BatchAudioConsumer` for the fallback) generic over `StreamingModelVariant`. Load with the concrete `loadModels(from:)` (EOU `StreamingEouAsrManager.swift:284`, Nemotron `StreamingNemotronAsrManager.swift:98`, Unified `StreamingUnifiedAsrManager.swift:81`) pointed at Echo's folder, not the protocol's no-arg `loadModels()` which uses FluidAudio's own cache dir. Because these managers are actors, ordering requires a single consumer: yield `[Float]` (Sendable) from the IO queue into an `AsyncStream` and have one Task do `appendAudio(AudioResampler.pcmBuffer(from:))` + `processBufferedAudio()` in order; `stopStreaming` finishes the stream, awaits the consumer, calls `finish()`, then `reset()`. Static cache + `isResident` + `evict` mirror `ParakeetProvider`. `TranscriptionService.isCold` and `ResidentEnginePolicy` call the same `ParakeetProvider.isResident/evict` facade.
- EOU end-of-utterance → auto-stop: `setEouCallback` fires after `eouDebounceMs` (default 1280) of model-predicted EOU with no new tokens (`StreamingEouAsrManager.swift:614-647`). Dictation has thinking pauses well over 1.3 s, so auto-paste would fire mid-thought; if offered at all, make it an opt-in "Auto-stop after N seconds of silence" toggle with N ≥ 2 s driven by Echo's own pause detector (engine-agnostic), not by the EOU token. Not recommended as default.
- Hybrid "paste EOU/Apple now, correct with TDT later": correcting already-pasted text means selecting and re-pasting in an arbitrary app (simulated shift-arrows / Cmd+Z), which flickers, breaks undo stacks, and is unsafe in terminals or chat inputs where Enter may already have been pressed. Verdict: do not paste twice. The only sensible use of a fast partial is as ghost text in the overlay (`GlobeOverlayView.swift:111-114` already shows `appState.partialTranscript`, though nothing feeds it today: `EchoCoordinator` only resets it at lines 174 and 299).

## 6. Phased rollout

| Phase | Deliverable | Exit criteria (numbers) | Effort |
|---|---|---|---|
| 0. Attribute the floor | `Latency.stopBreakdown` gains `tailSeconds`; a Release harness that times `manager.transcribe()` alone for 0.3 / 1 / 5 / 10 / 15 s clips, back-to-back and after 30 s idle; `echo.parakeetEncoderGPU` flag; `DictationCleanup.apply` timed on 10k words | A table: constant ms, ms per second of tail, idle penalty (if any), GPU delta, cleanup cost | 0.5–1 day |
| 1. Windows behind flag | `PauseAlignedWindowPipeline`, `ParakeetProvider` adopts `StreamingAudioConsumer`, whole-take fallback, `slidingWindow` comparator, debug capture toggle, parity + latency harnesses, AppSource tests | Parity acceptance in 4.3; 10 min take tail ≤ 300 ms; slope ≤ 0.2 ms/s | 3–4 days |
| 2. Speculative tail | Pause detector, speculative decode cache, invalidation, rate limit, `speculativeHit` logging | Hit rate ≥ 50% on real takes; hits p50 ≤ 70 ms stop→paste; misses within Phase 1 numbers | 1.5–2 days |
| 3. Default on + stop-path trims | `echo.parakeetStreaming` default `"speculative"`; device stop after paste; cleanup prewarm; header comment in `ParakeetProvider.swift` rewritten; `parakeetDeliberatelyDoesNotChunk` replaced | One week of field logs: p95 stop→paste ≤ 250 ms across all lengths | 0.5 day |
| 4. Fast engine (optional, decide after Phase 2) | `FluidStreamingProvider`, catalog/presence/download for Nemotron-1120 and EOU-320, Settings rows, harness WER/latency on the same corpus | Nemotron: WER ≤ batch TDT + 0.5 pp and stop→paste p50 ≤ 100 ms; EOU: report and let the user choose | 3–4 days |
| 5. Optional UX | Overlay ghost text from committed windows; opt-in silence auto-stop | User acceptance only | 1 day |

## 7. Risks, unknowns, de-risking experiments (run first)

- **E1 — where the 110 ms goes.** Time `transcribe()` for 0.3 / 5 / 15 s clips warm and after 30 s idle on this M1 Pro. If an idle penalty exists (ANE program re-residency), continuous window decoding removes it for free; if not, the constant is what it is. Also confirms the ~10 ms/s single-window slope.
- **E2 — `SlidingWindowAsrManager` behaviour.** Feed 5 s / 60 s / 10 min files in real time; measure `finish()` and diff text against batch. Expected: `finish()` ≈ one window pass; seams may show dup/drop words. Provides the A/B baseline for (e).
- **E3 — encoder on GPU.** `encoderComputeUnits: .cpuAndGPU`; check stop latency and any globe-overlay stutter.
- **E4 — pause statistics.** From captured takes: distribution of inter-word pauses, fraction of 5.5 s search windows with no ≥ 240 ms pause (forced-cut rate), and how long after the last word the hotkey is pressed (speculative hit rate).
- **E5 — punctuation at seams.** On the corpus, count end-of-window "." emissions with R = 0 vs R = 1.0 s to confirm the right-context argument; tune R (0.6–1.5 s).
- Unknowns: PnC output of Nemotron-EN / EOU (verify on the corpus); Unified decoder bundle size (HF listing looked wrong); M1 Pro per-chunk cost of Nemotron/EOU encoders (FluidAudio numbers are M2/M5).
- Risks: noisy rooms defeat the pause threshold (adaptive threshold relative to median frame energy, as `ChunkProcessor.adaptiveBoundaryThreshold` does; forced cut fallback); ANE contention with the Apple shadow on cold takes only; FluidAudio API drift (only public API used; pin 0.15.5); CPU spikes every ~8 s while talking (measure with the overlay); `AsrManager.transcribe` throws for < 0.3 s windows (pad audible tails to 1 s, drop silent ones, as `AudioChunkPipeline.swift:122-139`).

## 8. Stop-latency outside the model that can be trimmed

- `AudioEngineService.endCapture` (`/Users/fuadnafiz98/Developer/vibes/echo/echo/echo/Services/AudioEngineService.swift:405-412`) awaits `graph.stop()` (`AudioDeviceStop`, plus Bluetooth device release) *before* returning the snapshot, and `EchoCoordinator.stopRecording` awaits that flush before decoding (`EchoCoordinator.swift:250-254, 265`). Return the snapshot first and stop the device in a detached task after `deliver`; the collector already refuses frames once `capturing = false`. Saves a few ms of the measured 10.8 ms flush; mic indicator lingers ~200 ms.
- `ParakeetProvider.stopStreaming` (`ParakeetProvider.swift:135`) calls `resolvedSamples()`, which reads the CAF back for takes > 90 s (linear). Becomes fallback-only with streaming.
- `DictationCleanup.apply` (`EchoCoordinator.swift:316-322`) is linear in transcript length: `ReplacementEngine` runs cached regexes over the whole text, plus `FillerStripper` and the 331-line `SpokenPathNormalizer`. Measure on 10k words (E4 of Phase 0); if > 20 ms, clean committed windows incrementally during the take and only the last two pieces at stop.
- First take after launch shows a 47 ms transcript→paste gap (12:24:57.775 → .822 in the log) vs 3–5 ms afterwards: cold regex compilation / settings load. Prewarm `SpokenAliasTable.replacements` + `ReplacementEngine` in `EchoCoordinator.start()` off the main path (there is already a `HotPathBudget.cleanupFirstCall` budget in tests).
- `complete(with:)` (`TranscriptionService.swift:202-204`) and `stopRoute()` hops are microseconds; `clipboardTask` (`EchoCoordinator.swift:272`) is awaited only after decode and is normally finished. No change.
- `PasteService.paste` (`PasteService.swift:34-79`): clipboard write + two `CGEvent` posts, ~1–3 ms. No change.

## Tests to add (AppSource-grep style plus pure logic)

- `ParakeetStreamingInvariantTests`: `ParakeetProvider.swift` contains `StreamingAudioConsumer` and `PauseAlignedWindowPipeline`; `stopStreaming` has `pipeline.finish()` before `resolvedSamples()`, contains `sawAtLeast(frames:` and `retranscribing the whole take`; the window decode closure contains `TdtDecoderState.make` (fresh state) and `tokenTimings`; `startStreaming` installs the pipeline before `loadCached` (`appearsInOrder`).
- Pure: layout invariant `left + hardCap + right ≤ 14.9`; `choosePause` picks the pause centre, sets `forced` when none; `trim` punctuation attach rule and mid-word join; speculative cache invalidation with a counting fake decoder (speech → pause → stop: exactly one decode; speech → pause → speech → stop: two).
- Replace `StreamingRecognitionTests.parakeetDeliberatelyDoesNotChunk` with the inverse; keep `whisperFallsBackToTheWholeTakeOnChunkFailure` shape for Parakeet.
- Item 5: `LocalModelPathsTests`-style folder-name checks; presence probe uses known file paths; `evictInactive`/`evictLargeGraphs` cover the streaming backend; `TranscriptionService.isCold` handles it.

### Critical Files for Implementation
- /Users/fuadnafiz98/Developer/vibes/echo/echo/echo/Services/Transcription/ParakeetProvider.swift
- /Users/fuadnafiz98/Developer/vibes/echo/echo/echo/Services/Transcription/AudioChunkPipeline.swift (pattern to mirror for the new `PauseAlignedWindowPipeline.swift` beside it)
- /Users/fuadnafiz98/Developer/vibes/echo/echo/echo/Services/Transcription/TranscriptionService.swift
- /Users/fuadnafiz98/Developer/vibes/echo/echo/echo/EchoCoordinator.swift (stop path, breakdown logging, device-stop reorder)
- /Users/fuadnafiz98/Developer/vibes/echo/echo/echo/Services/Models/LocalModelCatalog.swift (item 5 catalog entries; with LocalModelPresence.swift / LocalModelIO.swift / LocalModelPaths.swift)

---

## Addendum (main session, not Fable): the cold load itself is 38 s

Measured after installing this session's build: `model load parakeet.v2 38342.5ms` at a plain app launch, with warmup only 111.6 ms. The 11:20 take (old binary, after eviction) had a ~40 s load as well. So the ANE compile cache is being missed on every load, not only after a reinstall. Today's Apple shadow hides this from paste latency, but it means every relaunch/eviction leaves Parakeet unusable for ~40 s.

First experiment (before Phase 0): quit and relaunch Echo **without rebuilding**, read `model load parakeet.v2`. ~38 s again → investigate CoreML/ANE caching (`MLModelConfiguration` / FluidAudio `AsrModels.load` options, model folder location, whether `aned` cache is keyed on something that changes); ~1–3 s → only rebuilds and evictions pay, which the `.critical`-only policy already minimises.

---

## Implementation status (2026-09-23)

Implemented on top of the plan, measured with `echoTests/ParakeetBenchmarkTests.swift` (Release,
M1 Pro, `say`-synthesised dictation with a known script; WER is against that script).

### What shipped

- `PauseWindowPipeline` (Services/Transcription/PauseWindowPipeline.swift): design (e) from §2 —
  pause-aligned windows, fresh decoder state per window, words assigned by first-token start time.
  Layout chosen by sweep: left 3.0 s, right 2.0 s, target 6 s, min 3.5 s, hard cap 9.9 s. Right
  context of 1 s (the plan's first guess) misheard words near cuts and turned sentence ends into
  commas; 2 s matched batch word accuracy exactly.
- Speculation (§3.4) plus three refinements the plan did not have:
  - **Reuse**: a pass that went stale because the speaker carried on is still used up to its pause
    (or, for a rolling pass, up to the quietest point 0.4 s before its end); stop decodes only
    what came after, with 1.5 s of left context.
  - **Rolling passes** every 3 s of continuous speech, so a mid-word stop never has more than a few
    seconds left. Swept: off 167 ms / 6% CPU, 3 s 135 ms / 9.9%, 1.5 s 134 ms / 15%.
  - **Stop intent** (Services/StopIntentMonitor.swift): during a take the hotkey's modifiers are
    polled (`CGEventSource.flagsState`, no permission); when they go down, passes run back to back
    until the key lands. Needed because any decode after ≥ 0.25 s idle costs ~30 ms more (CPU
    clock ramp: 135 → 112 ms with 100 ms of prior CPU load; decoder-on-CPU vs ANE made no
    difference).
- Seam punctuation: the window after a seam decides the punctuation at it (it heard both sides).
- Settings → General → Engine: Standard / Streaming segmented picker when Parakeet is active
  (`TranscriptionPipeline`, default Streaming).
- Parakeet stays resident through the 2 h idle backstop (+47 MB footprint measured; reloading can
  trigger a 30–38 s ANECompilerService recompile of the encoder, seen five times in one morning).
- Device stop moved off the transcript path; cleanup rules prewarmed after launch.

### Numbers (stop → transcript, median of 3)

| take | Standard (batch) | Streaming |
|---|---|---|
| 5 s, stop after a pause | 111 ms | 0.4 ms |
| 52 s | 310 ms | 0.8 ms |
| 158 s | 697 ms | 1.6 ms |
| 530 s | 2,145 ms | 3.6–5.2 ms |
| 51 s, stop 0.35 s after last word | 301 ms | 0.3 ms |
| 45 s, stop mid-word, modifiers seen 0.2 s before | 289 ms | 0.3 ms |
| 45 s, stop mid-word, no warning (menu bar) | 296 ms | 141–146 ms |

Word errors vs script: identical or better everywhere (530 s: batch 28/1900, streaming 0/1900).
Punctuation errors vs script at 158 s: 10 batch, 10 streaming. CPU while talking: ~10% of one
core (batch ~2%, all at stop). Idle footprint of the installed app: 51 MB vs 50 MB on master.

### Decided against

- Encoder on GPU: 216–528 ms per pass vs 90–210 ms on the ANE, and +1.2 GB footprint.
- Item 5 (Parakeet EOU 120M / Nemotron): the gate in §5.1 was "decide after Phase 2". Streaming
  TDT now hits ~0 ms on every stop that follows a pause or the hotkey's modifiers, with batch-level
  accuracy; the only miss is a mid-word stop with no warning (~140 ms). A second engine (225–626 MB
  download, 2–3.5x the word errors for EOU) does not buy enough to justify itself.
