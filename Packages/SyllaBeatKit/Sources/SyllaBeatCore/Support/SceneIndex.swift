import Foundation

/// Embeddings aller Szenen eines Projekts im Speicher, für die semantische Suche in der Bibliothek.
public struct SceneIndex: Sendable {
    public struct Hit: Sendable, Equatable {
        public var clipID: String
        public var sceneStart: Double
        public var score: Float
    }

    struct Entry: Sendable {
        var clipID: String
        var sceneID: String
        var sceneStart: Double
        var vector: [Float]
    }

    let entries: [Entry]

    public init(project: Project, model: String, cache: MediaCache = MediaCache()) {
        var entries: [Entry] = []
        for clip in project.clips {
            guard let fingerprint = clip.media.fingerprint,
                let file = EmbeddingFile.read(cache.embeddings(fingerprint: fingerprint, model: model))
            else { continue }
            for scene in clip.scenes {
                if let vector = file.vectors[MediaCache.key(forSceneStart: scene.start)] {
                    entries.append(Entry(clipID: clip.id, sceneID: scene.id, sceneStart: scene.start, vector: vector))
                }
            }
        }
        self.entries = entries
    }

    init(entries: [Entry]) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Mittleres, normiertes Szenen-Embedding je Clip (für Kapitel-Vorschläge).
    public func clipVectors() -> [String: [Float]] {
        var sums: [String: [Float]] = [:]
        for entry in entries {
            var sum = sums[entry.clipID] ?? [Float](repeating: 0, count: entry.vector.count)
            guard sum.count == entry.vector.count else { continue }
            for i in sum.indices { sum[i] += entry.vector[i] }
            sums[entry.clipID] = sum
        }
        return sums.mapValues { sum in
            let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return norm > 0 ? sum.map { $0 / norm } : sum
        }
    }
    public var count: Int { entries.count }

    /// Clips nach bester Szene sortiert (Skalarprodukt normierter Vektoren).
    public func rank(query: [Float]) -> [Hit] {
        var best: [String: Hit] = [:]
        for entry in entries where entry.vector.count == query.count {
            var score: Float = 0
            for i in query.indices { score += query[i] * entry.vector[i] }
            if score > best[entry.clipID]?.score ?? -.infinity {
                best[entry.clipID] = Hit(clipID: entry.clipID, sceneStart: entry.sceneStart, score: score)
            }
        }
        return best.values.sorted { $0.score > $1.score }
    }

    /// Ähnlichkeit jeder Szene (nach Szenen-ID) zu einem Text, für die Schnitt-Engine.
    public func similarities(query: [Float]) -> [String: Float] {
        var result: [String: Float] = [:]
        for entry in entries where entry.vector.count == query.count {
            var score: Float = 0
            for i in query.indices { score += query[i] * entry.vector[i] }
            result[entry.sceneID] = score
        }
        return result
    }

    /// Clip-IDs, deren Szenen noch kein Embedding haben.
    public static func missing(in project: Project, model: String, cache: MediaCache = MediaCache()) -> [String] {
        project.clips.filter { clip in
            guard !clip.scenes.isEmpty, let fingerprint = clip.media.fingerprint else { return false }
            let file = EmbeddingFile.read(cache.embeddings(fingerprint: fingerprint, model: model))
            return clip.scenes.contains { file?.vectors[MediaCache.key(forSceneStart: $0.start)] == nil }
        }.map(\.id)
    }
}
