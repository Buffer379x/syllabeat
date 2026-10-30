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

    /// Beleg für den Drehbuch-Vorschlag: je Abschnitt und Kapitel der mittlere z-Wert über die Zeilen des Abschnitts
    /// (bester Szenenwert je Kapitel, z-normiert über die Kapitel). Abschnitte ohne Zeilen bleiben leer.
    public static func chapterEvidence(_ project: Project, rows: [String: [String: Float]]) -> [String: [Double]] {
        guard let analysis = project.analysis, !project.story.chapters.isEmpty else { return [:] }
        let chapters = project.story.chapters
        var sceneChapter: [String: Int] = [:]
        for clip in project.clips {
            guard let index = chapters.firstIndex(where: { $0.id == clip.chapterID }) else { continue }
            for scene in clip.scenes { sceneChapter[scene.id] = index }
        }
        var result: [String: [Double]] = [:]
        for section in analysis.sections {
            let lines = analysis.lines.filter { $0.start >= section.start - 0.5 && $0.start < section.end - 0.5 }
            var sums = Array(repeating: 0.0, count: chapters.count)
            var used = 0
            for line in lines {
                guard let row = rows[line.id] else { continue }
                var best = Array(repeating: -Double.infinity, count: chapters.count)
                for (scene, value) in row {
                    if let chapter = sceneChapter[scene] { best[chapter] = max(best[chapter], Double(value)) }
                }
                let present = best.filter(\.isFinite)
                guard present.count >= 2, let lowest = present.min() else { continue }
                // Kapitel ohne Szene zählen wie das schwächste.
                best = best.map { $0.isFinite ? $0 : lowest }
                let mean = best.reduce(0, +) / Double(best.count)
                let deviation = (best.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(best.count))
                    .squareRoot()
                guard deviation > 0 else { continue }
                for index in sums.indices { sums[index] += (best[index] - mean) / deviation }
                used += 1
            }
            if used > 0 { result[section.id] = sums.map { $0 / Double(used) } }
        }
        return result
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
