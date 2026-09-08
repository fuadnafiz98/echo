import Testing
@testable import echo

@MainActor
@Suite("DictationCleanup")
struct DictationCleanupTests {
    private let paragraph = SpokenPathNormalizer.fixtureCases().last!.input
    private let wanted = SpokenPathNormalizer.fixtureCases().last!.expected

    private let vocabulary = ["aim2-core", "python.py", "feature.py"]
    private let userReplacements = [
        TextReplacement(heard: "aim two core", written: "aim2-core"),
        TextReplacement(heard: "m2", written: "aim2"),
    ]

    @Test func appliesPathFixturesAndReplacementsWithoutPolish() {
        let raw = "um \(paragraph) please open aim two core"
        let cleaned = DictationCleanup.apply(
            raw,
            stripFillers: true,
            vocabulary: vocabulary,
            userReplacements: userReplacements
        )
        #expect(cleaned.contains("@s_a_test"))
        #expect(cleaned.contains("/computers/developers/downloads"))
        #expect(cleaned.contains("aim2-core"))
        #expect(!cleaned.contains("um "))
        #expect(!cleaned.contains("aim two core"))
    }

    @Test func rejectsFillerStripThatEmptiesTheTake() {
        let raw = "um uh"
        let cleaned = DictationCleanup.apply(raw, stripFillers: true)
        #expect(cleaned == raw)
    }

    @Test func keepsMeaningOnShortTakes() {
        #expect(DictationCleanup.keepsMeaning("hello world", of: "um hello world"))
        #expect(!DictationCleanup.keepsMeaning("", of: "please keep this"))
    }

    @Test func replacementEngineDoesNotEatPriorLongerMatch() {
        let text = "ship m2 and aim2 today"
        let rules = [
            TextReplacement(heard: "aim2", written: "aim2-core"),
            TextReplacement(heard: "m2", written: "aim2"),
        ]
        let result = ReplacementEngine.apply(text, replacements: rules)
        #expect(result == "ship aim2 and aim2-core today")
    }

    @Test func spokenFormsAndReplacementsStayMillisecondCheap() {
        let terms = ["aim2-core", "echo.app", "python.py", "s1-mini", "whisperkit"]
        _ = terms.flatMap { SpokenForms.expansions(for: $0) }
        let formsTook = HotPathBudget.elapsed {
            _ = terms.flatMap { SpokenForms.expansions(for: $0) }
        }
        #expect(formsTook < HotPathBudget.paragraph, "SpokenForms.expansions took \(formsTook) (budget \(HotPathBudget.paragraph))")

        _ = ReplacementEngine.apply(paragraph, replacements: userReplacements)
        let replaceTook = HotPathBudget.elapsed {
            _ = ReplacementEngine.apply(paragraph, replacements: userReplacements)
        }
        #expect(replaceTook < HotPathBudget.paragraph, "ReplacementEngine.apply took \(replaceTook) (budget \(HotPathBudget.paragraph))")
    }

    @Test func localCleanupStaysMillisecondCheap() {
        let first = HotPathBudget.elapsed {
            _ = DictationCleanup.apply(
                paragraph,
                stripFillers: true,
                vocabulary: vocabulary,
                projectTerms: ["echo", "components"],
                userReplacements: userReplacements
            )
        }
        #expect(first < HotPathBudget.cleanupFirstCall, "DictationCleanup.apply first call took \(first) (budget \(HotPathBudget.cleanupFirstCall))")

        let warmed = HotPathBudget.elapsed {
            _ = DictationCleanup.apply(
                paragraph,
                stripFillers: true,
                vocabulary: vocabulary,
                projectTerms: ["echo", "components"],
                userReplacements: userReplacements
            )
        }
        #expect(warmed < HotPathBudget.paragraph, "DictationCleanup.apply took \(warmed) (budget \(HotPathBudget.paragraph))")
        #expect(DictationCleanup.apply(wanted, stripFillers: false) == wanted)
    }
}
