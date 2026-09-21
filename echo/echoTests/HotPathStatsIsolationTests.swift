import Foundation
import Testing
@testable import echo

/// Stats / STT-average / resource sampling must not sit on cleanup or paste.
@Suite("Hot-path stats isolation")
struct HotPathStatsIsolationTests {
    private static let sttRecordNeedles = [
        "recordSTT",
        "recordTranscription",
        "recordAverageSTT",
        "averageSTT",
        "sttDuration",
        "sttMilliseconds",
        "transcriptionMs",
        "transcriptionDuration",
        "recordLatency",
        "UsageStats.record",
    ]

    private static let sampleNeedles = [
        "ResourceStats",
        "ProcessMetrics",
        "GPUMetrics",
        "task_info",
        "host_processor",
        "host_statistics",
        "phys_footprint",
        "UsageStatsStore",
        "flushPending",
    ]

    @Test func deliverCleansThenPastesThenRecords() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let deliver = try #require(AppSource.method(source, named: "deliver"))
        #expect(
            AppSource.appearsInOrder(deliver, [
                "DictationCleanup.apply",
                "PasteService.paste",
                "UsageStats.recordSuccessfulPaste",
            ]),
            "deliver must be cleanup → paste → record. Got:\n\(deliver)"
        )
        #expect(!deliver.contains("TranscriptCleaner"))
        #expect(!deliver.contains("S1Mini"))
        #expect(!deliver.contains("await"))
        #expect(!deliver.contains("milliseconds(40)"))
        assertNoSampleWork(deliver, path: "deliver")
    }

    @Test func sttAverageRecordingIsAfterPasteNotBeforeCleanup() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let deliver = try #require(AppSource.method(source, named: "deliver"))
        let stop = try #require(AppSource.method(source, named: "stopRecording"))
        let start = try #require(AppSource.method(source, named: "startRecording"))

        let pasteAt = try #require(AppSource.firstIndex(of: "PasteService.paste", in: deliver))
        let cleanupAt = try #require(AppSource.firstIndex(of: "DictationCleanup.apply", in: deliver))
        #expect(cleanupAt < pasteAt, "cleanup must run before paste")

        for needle in Self.sttRecordNeedles {
            for range in AppSource.occurrences(of: needle, in: deliver) {
                #expect(
                    range.lowerBound >= pasteAt,
                    "\(needle) in deliver must be after PasteService.paste, not before cleanup"
                )
                #expect(
                    range.lowerBound > cleanupAt,
                    "\(needle) must not run before DictationCleanup.apply"
                )
            }
        }

        let deliverCall = try #require(AppSource.firstIndex(of: "deliver(raw)", in: stop))
        for needle in Self.sttRecordNeedles {
            for range in AppSource.occurrences(of: needle, in: stop) {
                #expect(
                    range.lowerBound > deliverCall,
                    "\(needle) in stopRecording must be after deliver(raw) / paste, not before cleanup"
                )
            }
        }

        assertNoSTTRecord(start, path: "startRecording")
        #expect(!start.contains("milliseconds(40)"))
    }

    @Test func stopToPasteHasNoSleepOrCAFTrim() throws {
        let coordinator = try AppSource.load("EchoCoordinator.swift")
        let stop = try #require(AppSource.method(coordinator, named: "stopRecording"))
        let deliver = try #require(AppSource.method(coordinator, named: "deliver"))
        let finish = try #require(
            AppSource.method(
                try AppSource.load("Services/Transcription/TranscriptionService.swift"),
                named: "finishAndTranscribe"
            )
        )

        for body in [stop, deliver, finish] {
            #expect(!body.contains("milliseconds(40)"))
            #expect(!body.contains("sleep(for: .milliseconds(40)"))
            #expect(!body.contains("trimSilence"))
            #expect(!body.contains("trimmingSilence"))
        }
        #expect(stop.contains("deliver(raw)"))
        #expect(!stop.contains("TranscriptCleaner"))
        #expect(!stop.contains("S1MiniEngine"))
        #expect(!deliver.contains("AppleSTT"))
        #expect(!deliver.contains("S1Mini"))
    }

    @Test func transcribeAndCleanupNeverRecordStats() throws {
        let finish = try #require(
            AppSource.method(
                try AppSource.load("Services/Transcription/TranscriptionService.swift"),
                named: "finishAndTranscribe"
            )
        )
        let cleanup = try AppSource.load("Services/Dictation/DictationCleanup.swift")
        assertNoSTTRecord(finish, path: "finishAndTranscribe")
        assertNoSampleWork(finish, path: "finishAndTranscribe")
        let apply = try #require(AppSource.method(cleanup, named: "apply"))
        let meaning = try #require(AppSource.method(cleanup, named: "keepsMeaning"))
        assertNoSTTRecord(cleanup, path: "DictationCleanup")
        assertNoSampleWork(cleanup, path: "DictationCleanup")
        #expect(!AppSource.containsAwaitKeyword(apply), "DictationCleanup.apply must stay synchronous")
        #expect(!AppSource.containsAwaitKeyword(meaning), "keepsMeaning must stay synchronous")
        #expect(!cleanup.contains("UsageStats"))
        #expect(!cleanup.contains("ResourceStats"))
    }

    @Test func parakeetAndWhisperStopDoNotTrimOrRecordStats() throws {
        let parakeet = try #require(
            AppSource.method(
                try AppSource.load("Services/Transcription/ParakeetProvider.swift"),
                named: "stopStreaming"
            )
        )
        let whisper = try #require(
            AppSource.method(
                try AppSource.load("Services/Transcription/WhisperKitProvider.swift"),
                named: "stopStreaming"
            )
        )
        for (name, body) in [("Parakeet", parakeet), ("Whisper", whisper)] {
            #expect(!body.contains("trimSilence"), "\(name) stopStreaming must not trim CAF")
            assertNoSTTRecord(body, path: "\(name).stopStreaming")
            assertNoSampleWork(body, path: "\(name).stopStreaming")
        }
    }

    /// Chip first, then the microphone, then the model.
    ///
    /// This used to require `beginCapture` before `panelController.show`. That is what made the
    /// overlay wait on a CoreAudio device start, so the order is deliberately inverted now. What
    /// still matters is that both come before the model prepare.
    @Test func startRecordingIsChipThenMicBeforeModelLoad() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let start = try #require(AppSource.method(source, named: "startRecording"))
        #expect(
            AppSource.appearsInOrder(start, [
                "panelController.show",
                "beginCapture",
                "transcriptionService.prepare",
            ]),
            "hotkey → listening must show the chip, then start the mic, then prepare. Got:\n\(start)"
        )
        assertNoSTTRecord(start, path: "startRecording")
        assertNoSampleWork(start, path: "startRecording")
    }

    @Test func usageRecordMethodsStayInMemory() throws {
        let source = try AppSource.load("Services/Usage/UsageStats.swift")
        var nameStart = source.startIndex
        var sawRecord = false
        while let range = source.range(of: "func record", range: nameStart..<source.endIndex) {
            let lineStart = source[range.lowerBound...].split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let name = lineStart.split(separator: " ").last.map(String.init) ?? "record"
            let body = try #require(AppSource.method(source, named: name))
            sawRecord = true
            #expect(!body.contains("JSONEncoder"), "\(name) must not encode on the paste path")
            #expect(!body.contains("write(to:"), "\(name) must not persist on the paste path")
            #expect(!body.contains("await"), "\(name) must stay synchronous")
            #expect(!body.contains("UsageStatsStore"), "\(name) must not touch the store")
            #expect(!body.contains("resources.json"))
            #expect(!body.contains("stats.json"))
            nameStart = range.upperBound
        }
        #expect(sawRecord, "UsageStats must keep an in-memory record* API")
    }

    @Test func knownGoodHotPathTimingsHold() {
        let paragraph = SpokenPathNormalizer.fixtureCases().last!.input
        let vocabulary = ["aim2-core", "python.py", "feature.py"]
        let replacements = [
            TextReplacement(heard: "aim two core", written: "aim2-core"),
            TextReplacement(heard: "m2", written: "aim2"),
        ]
        let terms = ["aim2-core", "echo.app", "python.py", "s1-mini", "whisperkit"]

        _ = terms.flatMap { SpokenForms.expansions(for: $0) }
        let forms = HotPathBudget.elapsed("SpokenForms.expansions warm") {
            _ = terms.flatMap { SpokenForms.expansions(for: $0) }
        }
        #expect(forms < HotPathBudget.paragraph)

        _ = ReplacementEngine.apply(paragraph, replacements: replacements)
        let replace = HotPathBudget.elapsed("ReplacementEngine.apply warm") {
            _ = ReplacementEngine.apply(paragraph, replacements: replacements)
        }
        #expect(replace < HotPathBudget.paragraph)

        _ = SpokenPathNormalizer.apply(paragraph)
        let path = HotPathBudget.elapsed("SpokenPathNormalizer.apply warm") {
            _ = SpokenPathNormalizer.apply(paragraph)
        }
        #expect(path < HotPathBudget.paragraph)

        _ = DictationCleanup.apply(
            paragraph,
            stripFillers: true,
            vocabulary: vocabulary,
            projectTerms: ["echo", "components"],
            userReplacements: replacements
        )
        let cleanup = HotPathBudget.elapsed("DictationCleanup.apply warm") {
            _ = DictationCleanup.apply(
                paragraph,
                stripFillers: true,
                vocabulary: vocabulary,
                projectTerms: ["echo", "components"],
                userReplacements: replacements
            )
        }
        #expect(cleanup < HotPathBudget.paragraph)
    }

    private func assertNoSTTRecord(_ source: String, path: String) {
        for needle in Self.sttRecordNeedles {
            #expect(!source.contains(needle), "\(path) must not contain \(needle)")
        }
    }

    private func assertNoSampleWork(_ source: String, path: String) {
        for needle in Self.sampleNeedles {
            #expect(!source.contains(needle), "\(path) must not contain \(needle)")
        }
    }
}
