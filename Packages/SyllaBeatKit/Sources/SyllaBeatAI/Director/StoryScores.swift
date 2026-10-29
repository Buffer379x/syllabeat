import Foundation
import SyllaBeatCore

/// Ähnlichkeiten für die Engine: Textzeilen und Storyboard-Suchbegriffe (je Abschnitt) gegen alle Szenen. Grundlage
/// sind die SigLIP-2-Embeddings; Beschreibungen und Schlagwörter aus der Bildbeschreibung geben einen kleinen Zuschlag,
/// wenn ein Wort wörtlich vorkommt.
public enum StoryScores {
    /// Zuschlag je Treffer und Obergrenze (SigLIP-Ähnlichkeiten liegen etwa zwischen 0 und 0,15).
    static let matchBonus: Float = 0.02
    static let maximumBonus: Float = 0.06

    public static func compute(
        _ storyboard: Storyboard, index: SceneIndex, descriptions: [String: Set<String>] = [:],
        isolation: isolated (any Actor)? = #isolation, embed: (String) async throws -> [Float]
    ) async throws -> [String: [String: Float]] {
        var cache: [String: [Float]] = [:]
        var result: [String: [String: Float]] = [:]
        for plan in storyboard.sections where !plan.searchTerms.isEmpty {
            var sum: [Float] = []
            for term in plan.searchTerms {
                let key = term.lowercased()
                let vector: [Float]
                if let cached = cache[key] {
                    vector = cached
                } else {
                    vector = try await embed(term)
                    cache[key] = vector
                }
                guard !vector.isEmpty else { continue }
                if sum.isEmpty { sum = Array(repeating: 0, count: vector.count) }
                guard sum.count == vector.count else { continue }
                for i in vector.indices { sum[i] += vector[i] }
            }
            let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0 else { continue }
            var row = index.similarities(query: sum.map { $0 / norm })
            addBonus(to: &row, words: words(plan.searchTerms.joined(separator: " ")), descriptions: descriptions)
            result[plan.sectionID] = row
        }
        return result
    }

    /// Wörter einer Szene: Szenenbeschreibung, Clipbeschreibung und Schlagwörter (klein, ab drei Buchstaben).
    public static func descriptions(of project: Project) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for clip in project.clips {
            let shared = words(([clip.description] + clip.tags + [clip.mood ?? ""]).joined(separator: " "))
            for scene in clip.scenes { result[scene.id] = shared.union(words(scene.description)) }
        }
        return result
    }

    public static func addBonus(
        to row: inout [String: Float], words query: Set<String>, descriptions: [String: Set<String>]
    ) {
        guard !query.isEmpty, !descriptions.isEmpty else { return }
        for (sceneID, sceneWords) in descriptions {
            let hits = query.filter { word in sceneWords.contains { $0.hasPrefix(word) || word.hasPrefix($0) } }.count
            guard hits > 0 else { continue }
            row[sceneID, default: 0] += min(maximumBonus, Float(hits) * matchBonus)
        }
    }

    public static func words(_ text: String) -> Set<String> {
        Set(
            text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 3 }
                .filter { !stopWords.contains($0) })
    }

    static let stopWords: Set<String> = [
        "und", "der", "die", "das", "ein", "eine", "einen", "dem", "den", "mit", "von", "bei", "auf", "für", "ist",
        "sich", "mich", "mir", "dich", "dir", "wie", "nur", "noch", "aus", "the", "and", "clip", "bild", "szene",
    ]
}
