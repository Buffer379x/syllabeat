import Foundation

/// Kapitel-Vorschlag für einen neuen Clip: Takes eines schon eingeordneten Motivs gehören sicher dazu; sonst das
/// Kapitel mit dem nächsten Bild-Schwerpunkt (im Spike 27/40 richtig, deshalb nur als Vorschlag zum Bestätigen).
public enum ChapterSuggester {
    /// `vectors`: mittleres, normiertes Szenen-Embedding je Clip-ID.
    public static func suggest(
        for clip: Clip, in project: Project, vectors: [String: [Float]]
    )
        -> (chapterID: String, sure: Bool)?
    {
        guard !project.story.chapters.isEmpty else { return nil }
        let motifs = project.motifs()
        if let motif = motifs[clip.id], motif.words.count >= 2 || motif.generator != nil || motif.copy > 1,
            let sibling = project.clips.first(where: {
                $0.id != clip.id && $0.chapterID != nil && motifs[$0.id]?.key == motif.key
            }), let chapter = sibling.chapterID
        {
            return (chapter, true)
        }
        guard let vector = vectors[clip.id] else { return nil }
        var best: (id: String, score: Float)?
        for chapter in project.story.chapters {
            let members = project.clips.filter { $0.id != clip.id && $0.chapterID == chapter.id }.compactMap {
                vectors[$0.id]
            }
            guard let first = members.first, first.count == vector.count else { continue }
            var centre = [Float](repeating: 0, count: vector.count)
            for member in members where member.count == vector.count {
                for i in member.indices { centre[i] += member[i] }
            }
            let norm = centre.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0 else { continue }
            let score = zip(vector, centre).reduce(Float(0)) { $0 + $1.0 * $1.1 } / norm
            if score > best?.score ?? -.infinity { best = (chapter.id, score) }
        }
        return best.map { ($0.id, false) }
    }
}

extension ChapterSuggester {
    /// Vorschläge für alle Clips ohne Kapitel in einem Durchgang (Motive und Schwerpunkte einmal berechnet).
    public static func suggestAll(
        in project: Project, vectors: [String: [Float]]
    ) -> [String: (chapterID: String, sure: Bool)] {
        guard !project.story.chapters.isEmpty else { return [:] }
        let motifs = project.motifs()
        var chapterOfMotif: [String: String] = [:]
        for clip in project.clips {
            guard let chapter = clip.chapterID, let motif = motifs[clip.id],
                motif.words.count >= 2 || motif.generator != nil || motif.copy > 1
            else { continue }
            chapterOfMotif[motif.key] = chapterOfMotif[motif.key] ?? chapter
        }
        var centres: [(id: String, centre: [Float])] = []
        for chapter in project.story.chapters {
            let members = project.clips.filter { $0.chapterID == chapter.id }.compactMap { vectors[$0.id] }
            guard let first = members.first else { continue }
            var centre = [Float](repeating: 0, count: first.count)
            for member in members where member.count == first.count {
                for i in member.indices { centre[i] += member[i] }
            }
            let norm = centre.reduce(0) { $0 + $1 * $1 }.squareRoot()
            if norm > 0 { centres.append((chapter.id, centre.map { $0 / norm })) }
        }
        var result: [String: (chapterID: String, sure: Bool)] = [:]
        for clip in project.clips where clip.chapterID == nil {
            if let motif = motifs[clip.id], motif.words.count >= 2 || motif.generator != nil || motif.copy > 1,
                let chapter = chapterOfMotif[motif.key]
            {
                result[clip.id] = (chapter, true)
                continue
            }
            guard let vector = vectors[clip.id] else { continue }
            let best = centres.filter { $0.centre.count == vector.count }.max { a, b in
                zip(vector, a.centre).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                    < zip(vector, b.centre).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            }
            if let best { result[clip.id] = (best.id, false) }
        }
        return result
    }
}
