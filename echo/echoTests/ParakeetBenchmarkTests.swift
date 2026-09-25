import AVFoundation
import CoreML
import Darwin
import FluidAudio
import Foundation
import Testing

@testable import echo

/// Stop cost, accuracy and memory for Parakeet, on real synthesised speech with a known script.
///
/// Every change to the Parakeet path is measured against the numbers this writes, so it runs the
/// same fixtures in the same order each time and appends one JSON object per measurement to
/// `$ECHO_BENCH_OUT/<label>.jsonl`. Accuracy is word error rate against the script `say` read,
/// which is ground truth rather than another model's guess.
///
/// Disabled by default: it needs the downloaded model and takes minutes. Run in Release so the
/// decode loop is optimised the way it is in the shipped app:
///
///     TEST_RUNNER_ECHO_PARAKEET_BENCH=1 TEST_RUNNER_ECHO_BENCH_OUT=<dir> \
///     TEST_RUNNER_ECHO_BENCH_LABEL=baseline \
///     xcodebuild test -scheme echo -configuration Release ENABLE_TESTABILITY=YES \
///       -only-testing:echoTests/ParakeetBenchmarkTests ...
@Suite(
    "Parakeet benchmark",
    .serialized,
    .disabled(if: ProcessInfo.processInfo.environment["ECHO_PARAKEET_BENCH"] == nil)
)
struct ParakeetBenchmarkTests {
    static let variant = ParakeetVariant.v2English

    @Test func benchmark() async throws {
        let out = BenchOutput()
        let layout = BenchMode.layout
        out.record([
            "kind": "start",
            "footprintMB": Memory.footprintMB(),
            "layout": "\(layout.leftContext),\(layout.rightContext),\(layout.targetWindow),\(layout.minWindow),\(layout.hardCap),rolling=\(layout.rollingInterval ?? 0)",
        ])

        // Cold load. The test host is the app, which starts its own prewarm at launch; this joins
        // that load rather than starting a second one, so it is an upper bound on the true cost.
        let loadStart = CFAbsoluteTimeGetCurrent()
        let (manager, layers) = try await ParakeetProvider.managerForBenchmark(variant: Self.variant)
        out.record([
            "kind": "load",
            "ms": ms(since: loadStart),
            "footprintMB": Memory.footprintMB(),
        ])

        let fixtures = try Fixtures.all()

        if ProcessInfo.processInfo.environment["ECHO_BENCH_GPU"] != nil,
           let speech = fixtures.first(where: { $0.name == "p60" }) {
            try await Self.encoderPlacement(speech: speech, out: out)
        }

        // Floor attribution: one bare `transcribe` per clip length, warm.
        if ProcessInfo.processInfo.environment["ECHO_BENCH_IDLE_CURVE"] != nil,
           let speech = fixtures.first(where: { $0.name == "p60" }) {
            if ProcessInfo.processInfo.environment["ECHO_BENCH_WAKE"] != nil {
                try await Self.wakeCause(speech: speech, manager: manager, layers: layers, out: out)
                return
            }
            try await Self.idleCurve(speech: speech, manager: manager, layers: layers, label: "idleCurve", out: out)
            if ProcessInfo.processInfo.environment["ECHO_BENCH_DECODER_CPU"] != nil,
               let folder = LocalModelPresence.folder(for: .parakeet(Self.variant)) {
                // Encoder on the ANE, the small per-token decoder and joint models on the CPU.
                let config = MLModelConfiguration()
                config.computeUnits = .cpuOnly
                let models = try await AsrModels.load(
                    from: folder,
                    configuration: config,
                    version: .v2,
                    encoderComputeUnits: .cpuAndNeuralEngine
                )
                let cpuManager = AsrManager(config: .default)
                try await cpuManager.loadModels(models)
                let cpuLayers = await cpuManager.decoderLayerCount
                try await Self.idleCurve(speech: speech, manager: cpuManager, layers: cpuLayers, label: "idleCurveDecoderCPU", out: out)
                var state = TdtDecoderState.make(decoderLayers: cpuLayers)
                let check = try await cpuManager.transcribe(Array(speech.samples.prefix(16_000 * 14)), decoderState: &state)
                out.record(["kind": "decoderCPUText", "text": check.text])
                var ref = TdtDecoderState.make(decoderLayers: layers)
                let base = try await manager.transcribe(Array(speech.samples.prefix(16_000 * 14)), decoderState: &ref)
                out.record(["kind": "decoderANEText", "text": base.text])
            }
            return
        }

        let skipFloor = ProcessInfo.processInfo.environment["ECHO_BENCH_SKIP_FLOOR"] != nil
        if !skipFloor, let speech = fixtures.first(where: { $0.name == "p60" }) {
            for seconds in [0.3, 1.0, 2.0, 4.0, 8.0, 14.5] {
                let clip = Array(speech.samples.prefix(Int(seconds * AudioResampler.targetSampleRate)))
                var timings: [Double] = []
                for _ in 0..<5 {
                    var state = TdtDecoderState.make(decoderLayers: layers)
                    let start = CFAbsoluteTimeGetCurrent()
                    _ = try await manager.transcribe(clip, decoderState: &state)
                    timings.append(ms(since: start))
                }
                out.record([
                    "kind": "transcribe",
                    "clipSeconds": seconds,
                    "medianMs": median(timings),
                    "minMs": timings.min() ?? 0,
                ])
            }
            // Idle penalty: does the first call after a quiet spell pay extra?
            try await Task.sleep(for: .seconds(20))
            let clip = Array(speech.samples.prefix(Int(AudioResampler.targetSampleRate)))
            var state = TdtDecoderState.make(decoderLayers: layers)
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await manager.transcribe(clip, decoderState: &state)
            out.record(["kind": "transcribeAfterIdle", "clipSeconds": 1.0, "ms": ms(since: start)])
        }

        var cases = fixtures
        // Stopping mid-word: the worst case for streaming, which must then decode the tail.
        if let base = fixtures.first(where: { $0.name == "p60" }) {
            let midword = Fixtures.cutMidWord(base)
            cases.append(midword)
            // The stop shortcut's modifiers 200 ms before Space, while the word is still going.
            cases.append(Fixture(name: "p60-midword-early", script: "", samples: midword.samples, anticipateBeforeEnd: 0.2))
            // Space 0.35 s after the last word: sooner than a pause pass can finish on its own.
            let quick = Fixtures.quickStop(base)
            cases.append(quick)
            cases.append(Fixture(name: "p60-quick-early", script: quick.script, samples: quick.samples, anticipateBeforeEnd: 0.15))
        }

        var batchTranscripts: [String: String] = [:]
        for mode in BenchMode.selected {
            for fixture in cases {
                var stops: [Double] = []
                var transcript = ""
                var peakMB = 0.0
                var hits = 0
                var reuses = 0
                var tails: [Double] = []
                var cpu: [Double] = []
                var finalDecode: [Double] = []
                var stats: PauseWindowPipeline.Stats?
                var paths: [String] = []
                let reps = ProcessInfo.processInfo.environment["ECHO_BENCH_REPS"].flatMap(Int.init) ?? (fixture.seconds > 300 ? 2 : 3)
                for _ in 0..<reps {
                    let run = try await Self.take(fixture, mode: mode)
                    stops.append(run.stopMs)
                    cpu.append(run.cpuSeconds)
                    transcript = run.transcript
                    peakMB = max(peakMB, run.peakFootprintMB)
                    if let s = run.stats {
                        stats = s
                        tails.append(s.tailSeconds)
                        finalDecode.append(s.finalDecodeMilliseconds)
                        if s.speculativeHit { hits += 1 }
                        if s.reusedSpeculation { reuses += 1 }
                        paths.append(s.stopPath)
                    }
                }
                if mode == .batch { batchTranscripts[fixture.name] = transcript }
                let vsBatch = batchTranscripts[fixture.name].map {
                    WordErrorRate.compute(reference: $0, hypothesis: transcript, keepPunctuation: true)
                }
                let wer = WordErrorRate.compute(reference: fixture.script, hypothesis: transcript)
                let punct = WordErrorRate.compute(
                    reference: fixture.script,
                    hypothesis: transcript,
                    keepPunctuation: true
                )
                out.record([
                    "kind": "take",
                    "mode": mode.rawValue,
                    "fixture": fixture.name,
                    "audioSeconds": fixture.seconds,
                    "stopMedianMs": median(stops),
                    "stopMaxMs": stops.max() ?? 0,
                    "wer": wer.rate,
                    "werPunct": punct.rate,
                    "diffVsBatch": vsBatch?.errors ?? -1,
                    "stopPaths": paths,
                    "errorsPunct": punct.errors,
                    "errors": wer.errors,
                    "refWords": wer.referenceWords,
                    "peakFootprintMB": peakMB,
                    "speculativeHits": hits,
                    "reusedSpeculations": reuses,
                    "reps": reps,
                    "tailSecondsMedian": median(tails),
                    "cuts": stats?.cuts ?? 0,
                    "forcedCuts": stats?.forcedCuts ?? 0,
                    "speculations": stats?.speculations ?? 0,
                    "rolling": stats?.rollingSpeculations ?? 0,
                    "cpuPercentOfAudio": median(cpu) / fixture.seconds * 100,
                    "finalDecodeMsMedian": median(finalDecode),
                ])
                Latency.note(
                    "BENCH \(mode.rawValue) \(fixture.name) audio=\(String(format: "%.1f", fixture.seconds))s "
                        + "stop=\(String(format: "%.0f", median(stops)))ms wer=\(String(format: "%.3f", wer.rate))"
                )
                out.record(["kind": "transcript", "mode": mode.rawValue, "fixture": fixture.name, "text": transcript])
            }
        }
        out.record(["kind": "end", "footprintMB": Memory.footprintMB()])
    }

    /// What wakes slowly after a gap: the CPU clock or the Neural Engine?
    static func wakeCause(speech: Fixture, manager: AsrManager, layers: Int, out: BenchOutput) async throws {
        let clip = Array(speech.samples.prefix(Int(2.7 * AudioResampler.targetSampleRate)))
        let tiny = Array(speech.samples.prefix(Int(0.3 * AudioResampler.targetSampleRate)))
        for variant in ["plain", "cpuSpin", "tinyDecodeFirst"] {
            var timings: [Double] = []
            for _ in 0..<6 {
                try await Task.sleep(for: .seconds(1))
                if variant == "cpuSpin" {
                    let until = CFAbsoluteTimeGetCurrent() + 0.1
                    var x = 0.0
                    while CFAbsoluteTimeGetCurrent() < until { x += sin(x + 1) }
                    if x == .infinity { print(x) }
                } else if variant == "tinyDecodeFirst" {
                    var warm = TdtDecoderState.make(decoderLayers: layers)
                    _ = try await manager.transcribe(tiny, decoderState: &warm)
                }
                var state = TdtDecoderState.make(decoderLayers: layers)
                let start = CFAbsoluteTimeGetCurrent()
                _ = try await manager.transcribe(clip, decoderState: &state)
                timings.append(ms(since: start))
            }
            out.record(["kind": "wake", "variant": variant, "medianMs": median(timings), "minMs": timings.min() ?? 0])
        }
    }

    /// How much a pause since the last decode costs the next one.
    static func idleCurve(speech: Fixture, manager: AsrManager, layers: Int, label: String, out: BenchOutput) async throws {
        let clip = Array(speech.samples.prefix(Int(2.7 * AudioResampler.targetSampleRate)))
        for gap in [0.0, 0.25, 1.0, 3.0] {
            var timings: [Double] = []
            for _ in 0..<5 {
                try await Task.sleep(for: .seconds(gap))
                var state = TdtDecoderState.make(decoderLayers: layers)
                let start = CFAbsoluteTimeGetCurrent()
                _ = try await manager.transcribe(clip, decoderState: &state)
                timings.append(ms(since: start))
            }
            out.record(["kind": label, "gapSeconds": gap, "medianMs": median(timings), "minMs": timings.min() ?? 0])
        }
    }

    /// Same floor measurement with the encoder on the GPU instead of the Neural Engine.
    static func encoderPlacement(speech: Fixture, out: BenchOutput) async throws {
        guard let folder = LocalModelPresence.folder(for: .parakeet(variant)) else { return }
        let before = Memory.footprintMB()
        let start = CFAbsoluteTimeGetCurrent()
        let models = try await AsrModels.load(from: folder, version: .v2, encoderComputeUnits: .cpuAndGPU)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let layers = await manager.decoderLayerCount
        out.record([
            "kind": "gpuLoad",
            "ms": ms(since: start),
            "footprintDeltaMB": Memory.footprintMB() - before,
        ])
        for seconds in [0.3, 1.0, 4.0, 8.0, 14.5] {
            let clip = Array(speech.samples.prefix(Int(seconds * AudioResampler.targetSampleRate)))
            var timings: [Double] = []
            for _ in 0..<6 {
                var state = TdtDecoderState.make(decoderLayers: layers)
                let t = CFAbsoluteTimeGetCurrent()
                _ = try await manager.transcribe(clip, decoderState: &state)
                timings.append(ms(since: t))
            }
            out.record([
                "kind": "transcribeGPU",
                "clipSeconds": seconds,
                "medianMs": median(Array(timings.dropFirst())),
                "minMs": timings.min() ?? 0,
            ])
        }
        await manager.cleanup()
    }

    struct Run {
        var stopMs: Double
        var transcript: String
        var peakFootprintMB: Double
        var stats: PauseWindowPipeline.Stats?
        /// Process CPU seconds for the whole take, feeding included.
        var cpuSeconds: Double
    }

    /// One take as the app runs it: start, audio in the collector's drain cadence, stop.
    static func take(_ fixture: Fixture, mode: BenchMode) async throws -> Run {
        let cpuStart = Memory.cpuSeconds()
        let provider = ParakeetProvider(variant: variant, pipeline: mode.pipeline, layout: BenchMode.layout)
        try await provider.startStreaming()
        var peak = Memory.footprintMB()

        // The collector drains in 4096-frame buffers. Streaming gets them as it would live; batch
        // only ever sees the snapshot at stop. Feeding runs at 8x real time to keep long fixtures
        // affordable, then real time for the last 10 s so the final pause behaves as it does live.
        let chunk = 4_096
        let chunkSeconds = Double(chunk) / AudioResampler.targetSampleRate
        let realTimeFrom = max(0, fixture.samples.count - Int(10 * AudioResampler.targetSampleRate))
        let anticipateAt = fixture.anticipateBeforeEnd.map {
            fixture.samples.count - Int($0 * AudioResampler.targetSampleRate)
        }
        var anticipated = false
        var offset = 0
        while offset < fixture.samples.count {
            let end = min(offset + chunk, fixture.samples.count)
            if mode.feedsLive, let at = anticipateAt, !anticipated, end >= at {
                provider.anticipateStop()
                anticipated = true
            }
            if mode.feedsLive, let buffer = AudioResampler.pcmBuffer(from: Array(fixture.samples[offset..<end])) {
                provider.consumeStreamingBuffer(buffer)
                let pace = offset >= realTimeFrom ? chunkSeconds : chunkSeconds / 8
                try await Task.sleep(for: .seconds(pace))
                if offset % (chunk * 32) == 0 {
                    peak = max(peak, Memory.footprintMB())
                }
            }
            offset = end
        }

        provider.consumeCapture(AudioCaptureSnapshot(
            samples: fixture.samples,
            fileURL: nil,
            capturedFrames: fixture.samples.count
        ))
        let stoppedAt = CFAbsoluteTimeGetCurrent()
        let text = try await provider.stopStreaming()
        let stopMs = ms(since: stoppedAt)
        peak = max(peak, Memory.footprintMB())
        return Run(
            stopMs: stopMs,
            transcript: text,
            peakFootprintMB: peak,
            stats: provider.lastStreamingStats,
            cpuSeconds: Memory.cpuSeconds() - cpuStart
        )
    }
}

// MARK: - Modes

enum BenchMode: String, CaseIterable {
    case batch
    case streaming

    var feedsLive: Bool { self == .streaming }

    var pipeline: TranscriptionPipeline {
        switch self {
        case .batch: .standard
        case .streaming: .streaming
        }
    }

    /// `ECHO_BENCH_LAYOUT=left,right,target,min,hardCap` for context sweeps.
    static var layout: PauseWindowPipeline.Layout {
        guard let raw = ProcessInfo.processInfo.environment["ECHO_BENCH_LAYOUT"] else { return .standard }
        let v = raw.split(separator: ",").compactMap { Double($0) }
        guard v.count >= 5 else { return .standard }
        var layout = PauseWindowPipeline.Layout()
        layout.leftContext = v[0]
        layout.rightContext = v[1]
        layout.targetWindow = v[2]
        layout.minWindow = v[3]
        layout.hardCap = v[4]
        if v.count >= 6 { layout.rollingInterval = v[5] > 0 ? v[5] : nil }
        if v.count >= 7 { layout.finalLeftContext = v[6] }
        if v.count >= 8 { layout.rollingMargin = v[7] }
        return layout
    }

    static var selected: [BenchMode] {
        guard let raw = ProcessInfo.processInfo.environment["ECHO_BENCH_MODES"] else { return allCases }
        return raw.split(separator: ",").compactMap { BenchMode(rawValue: String($0)) }
    }
}

// MARK: - Fixtures

struct Fixture {
    var name: String
    var script: String
    var samples: [Float]
    /// Seconds before the end at which the stop shortcut's modifiers go down.
    var anticipateBeforeEnd: Double?
    var seconds: Double { Double(samples.count) / AudioResampler.targetSampleRate }
}

enum Fixtures {
    /// Name → approximate words. At 190 wpm: p5 ≈ 5 s, p600 ≈ 10 min.
    static let plan: [(String, Int)] = [
        ("p5", 16), ("p15", 48), ("p30", 95), ("p60", 190), ("p180", 570), ("p600", 1_900),
    ]

    static func all() throws -> [Fixture] {
        // Real takes saved by `StreamingComparison`. No script: judge them against batch.
        if let dir = ProcessInfo.processInfo.environment["ECHO_BENCH_TAKES"] {
            let files = try FileManager.default
                .contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "wav" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            return try files.map {
                Fixture(
                    name: $0.deletingPathExtension().lastPathComponent,
                    script: "",
                    samples: try readMono16k($0),
                    anticipateBeforeEnd: ProcessInfo.processInfo.environment["ECHO_BENCH_ANTICIPATE"].flatMap(Double.init)
                )
            }
        }
        let only = ProcessInfo.processInfo.environment["ECHO_BENCH_FIXTURES"]
            .map { Set($0.split(separator: ",").map(String.init)) }
        return try plan
            .filter { only?.contains($0.0) ?? true }
            .map { try make(name: $0.0, words: $0.1) }
    }

    static func make(name: String, words: Int) throws -> Fixture {
        let script = Self.script(words: words)
        let cache = BenchOutput.directory.appendingPathComponent("fixture-\(name)-\(script.hashValueStable).wav")
        if !FileManager.default.fileExists(atPath: cache.path) {
            try synthesize(script, to: cache)
        }
        var samples = try readMono16k(cache)
        // `say` stops dead on the last phoneme; people pause before they press stop.
        samples.append(contentsOf: [Float](repeating: 0, count: Int(0.8 * AudioResampler.targetSampleRate)))
        return Fixture(name: name, script: script, samples: samples)
    }

    /// The whole fixture, but with only 0.35 s between the last word and stop.
    static func quickStop(_ base: Fixture) -> Fixture {
        let rate = Int(AudioResampler.targetSampleRate)
        var end = base.samples.count
        while end > 0, abs(base.samples[end - 1]) < 0.001 { end -= 1 }
        end = min(base.samples.count, end + Int(0.35 * Double(rate)))
        return Fixture(name: "p60-quick", script: base.script, samples: Array(base.samples[0..<end]))
    }

    /// The first 45 s, ending inside a word rather than after the natural pause.
    static func cutMidWord(_ base: Fixture) -> Fixture {
        let rate = Int(AudioResampler.targetSampleRate)
        var end = min(base.samples.count, 45 * rate)
        // Walk forward to a loud 20 ms frame: that is the middle of a word.
        while end + 320 < base.samples.count {
            let frame = base.samples[end..<end + 320]
            let rms = (frame.reduce(0) { $0 + $1 * $1 } / 320).squareRoot()
            if rms > 0.05 { break }
            end += 320
        }
        return Fixture(name: "p60-midword", script: "", samples: Array(base.samples[0..<end]))
    }

    static func script(words: Int) -> String {
        let corpus = paragraphs.joined(separator: " ").split(separator: " ")
        var picked: [Substring] = []
        var index = 0
        while picked.count < words {
            picked.append(corpus[index % corpus.count])
            index += 1
        }
        var text = picked.joined(separator: " ")
        if let last = text.last, !".?!".contains(last) {
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: ",;:")) + "."
        }
        return text
    }

    private static func synthesize(_ phrase: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, "--data-format=LEF32@16000", "--file-format=WAVE", "-r", "190", phrase]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "EchoBench", code: 1)
        }
    }

    private static func readMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw NSError(domain: "EchoBench", code: 2) }
        try file.read(into: buffer)
        guard let converted = AudioResampler.convertToMono16k(buffer) else { throw NSError(domain: "EchoBench", code: 3) }
        return AudioResampler.floats(from: converted)
    }

    /// Dictation-like prose. No digits: `say` reads them one way and the model may write them another.
    static let paragraphs = [
        "Hey team, quick update on the release. The build is green again after the flaky network test was fixed, and I think we can ship the beta on Thursday if nobody objects. Please take a look at the change log before then and flag anything that looks wrong.",
        "I want to rewrite the settings screen so it uses the native form controls instead of the custom cards we have now. The current version looks like a web page, and it does not respect the system accent color or the reduced transparency preference.",
        "Can you remind me to call the dentist tomorrow morning and to pick up groceries on the way home? We need milk, eggs, spinach, a loaf of sourdough bread, and whatever coffee is on sale this week.",
        "The main problem with the old approach is that it waited until the very end to do all of the work. When somebody talked for a long time, they had to sit and watch a spinner while the whole recording was processed from the beginning.",
        "Let us move the meeting to Friday afternoon. Most of the design team is traveling on Wednesday, and I would rather have everybody in the room when we decide how the onboarding flow should work for new users.",
        "In the function that handles the audio buffers, make sure we never allocate memory on the real time thread. Copy the samples into the ring buffer, signal the consumer, and return as quickly as possible so the hardware never drops a frame.",
        "Honestly the new laptop is great. The battery lasts all day, the speakers are surprisingly good, and the keyboard feels much better than the old one. The only thing I miss is the extra port on the left side.",
        "Please write a short summary of the customer interviews. Focus on the three things people complained about most, which were slow exports, confusing sharing permissions, and the lack of a dark theme on the web dashboard.",
    ]
}

// MARK: - Measurement helpers

enum WordErrorRate {
    struct Result {
        var rate: Double
        var errors: Int
        var referenceWords: Int
    }

    /// With `keepPunctuation`, sentence punctuation and capitalisation count as tokens too, so a
    /// seam that turns "release. The" into "release, the" is an error.
    static func compute(reference: String, hypothesis: String, keepPunctuation: Bool = false) -> Result {
        let ref = keepPunctuation ? tokens(reference) : normalize(reference)
        let hyp = keepPunctuation ? tokens(hypothesis) : normalize(hypothesis)
        guard !ref.isEmpty else { return Result(rate: hyp.isEmpty ? 0 : 1, errors: hyp.count, referenceWords: 0) }
        var previous = Array(0...hyp.count)
        var current = [Int](repeating: 0, count: hyp.count + 1)
        for i in 1...ref.count {
            current[0] = i
            if !hyp.isEmpty {
                for j in 1...hyp.count {
                    let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
                    current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                }
            }
            swap(&previous, &current)
        }
        let errors = previous[hyp.count]
        return Result(rate: Double(errors) / Double(ref.count), errors: errors, referenceWords: ref.count)
    }

    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var word = ""
        for character in text.replacingOccurrences(of: "-", with: " ") {
            if character.isLetter || character.isNumber || character == "'" {
                word.append(character)
            } else {
                if !word.isEmpty { out.append(word); word = "" }
                if ".,?!;:".contains(character) { out.append(String(character)) }
            }
        }
        if !word.isEmpty { out.append(word) }
        return out
    }

    static func normalize(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }
}

enum Memory {
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}

final class BenchOutput {
    static var directory: URL {
        let path = ProcessInfo.processInfo.environment["ECHO_BENCH_OUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("echo-bench").path
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let url: URL

    init() {
        let label = ProcessInfo.processInfo.environment["ECHO_BENCH_LABEL"] ?? "run"
        url = Self.directory.appendingPathComponent("\(label).jsonl")
        try? Data().write(to: url)
    }

    func record(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }
}

func ms(since start: CFAbsoluteTime) -> Double {
    (CFAbsoluteTimeGetCurrent() - start) * 1_000
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted.count.isMultiple(of: 2)
        ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        : sorted[sorted.count / 2]
}

private extension String {
    /// `hashValue` is seeded per process; fixtures are cached across runs.
    var hashValueStable: String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
