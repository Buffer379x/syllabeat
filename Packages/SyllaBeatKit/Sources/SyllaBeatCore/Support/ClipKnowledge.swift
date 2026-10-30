import Foundation

/// Was der Nutzer über eine Datei weiß, unabhängig vom Projekt: Sperrbereiche, Bewertung, „Nie verwenden“ und selbst
/// gesetzte Merkmale. Liegt je Fingerprint im Zwischenspeicher (`knowledge.json`), damit dieselben Clips in der nächsten
/// Folge einer Serie nicht neu gesichtet werden müssen.
public struct ClipKnowledge: Codable, Sendable, Equatable {
    public var blocked: [SourceRange]
    public var rating: Int?
    public var excluded: Bool
    /// Nur Werte mit Herkunft Nutzer.
    public var traits: [String: TraitValue]

    public init(_ clip: Clip) {
        blocked = clip.blocked
        rating = clip.rating
        excluded = clip.excluded
        traits = clip.traits.filter { $0.value.source == .user }
    }

    public var isEmpty: Bool { blocked.isEmpty && rating == nil && !excluded && traits.isEmpty }

    public static func load(fingerprint: String, cache: MediaCache) -> ClipKnowledge? {
        guard let data = try? Data(contentsOf: cache.knowledge(fingerprint: fingerprint)) else { return nil }
        return try? JSONDecoder().decode(ClipKnowledge.self, from: data)
    }

    public func save(fingerprint: String, cache: MediaCache) throws {
        _ = try cache.prepare(fingerprint: fingerprint)
        let url = cache.knowledge(fingerprint: fingerprint)
        if isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        }
    }

    /// Clips, deren Wissen sich zwischen zwei Projektständen geändert hat (nach Bearbeitung, Undo, Redo).
    public static func changes(from old: Project, to new: Project) -> [Clip] {
        let before = Dictionary(old.clips.map { ($0.id, ClipKnowledge($0)) }, uniquingKeysWith: { first, _ in first })
        return new.clips.filter { before[$0.id] != ClipKnowledge($0) }
    }
}

extension Clip {
    /// Übernimmt gemerktes Wissen nur in leere Felder; Werte im Projekt haben Vorrang. Zählt übernommene Angaben.
    public func adopting(_ knowledge: ClipKnowledge) -> (clip: Clip, adopted: Int) {
        var clip = self
        var adopted = 0
        if clip.blocked.isEmpty, !knowledge.blocked.isEmpty {
            clip.blocked = knowledge.blocked
            adopted += 1
        }
        if clip.rating == nil, let rating = knowledge.rating {
            clip.rating = rating
            adopted += 1
        }
        if !clip.excluded, knowledge.excluded {
            clip.excluded = true
            adopted += 1
        }
        for (id, value) in knowledge.traits where clip.traits[id]?.source != .user {
            clip.traits[id] = value
            adopted += 1
        }
        return (clip, adopted)
    }
}
