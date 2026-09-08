import Foundation

enum VocabIndex {
    @MainActor
    static func speechHints(scene: DictationScene, settings: DictationSettings) -> [String] {
        var terms = settings.vocabulary
        if settings.useFrontmostProject, let root = scene.projectRoot {
            terms.append(root.lastPathComponent)
        }
        var seen = Set<String>()
        var unique: [String] = []
        for term in terms {
            let key = term.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            unique.append(term)
            if unique.count >= DictationSettings.maxHintTerms { break }
        }
        return unique
    }
}
