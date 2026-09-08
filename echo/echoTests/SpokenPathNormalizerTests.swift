import Testing
@testable import echo

@Suite("SpokenPathNormalizer")
struct SpokenPathNormalizerTests {
    @Test func fixtureCasesPass() {
        let failures = SpokenPathNormalizer.failedFixtureCases()
        let detail = failures.map { "\($0.name): expected \($0.expected) got \($0.got)" }.joined(separator: "\n")
        #expect(failures.isEmpty, "\(detail)")
    }

    @Test func paragraphStaysMillisecondCheap() {
        let sentence = SpokenPathNormalizer.fixtureCases().last!.input
        _ = SpokenPathNormalizer.apply(sentence)

        let took = HotPathBudget.elapsed {
            _ = SpokenPathNormalizer.apply(sentence)
        }
        #expect(took < HotPathBudget.paragraph, "SpokenPathNormalizer.apply took \(took) (budget \(HotPathBudget.paragraph))")
    }
}
