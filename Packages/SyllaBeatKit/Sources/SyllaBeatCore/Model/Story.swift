import Foundation

/// Die Geschichte eines Musikvideos: Kapitel in Erzählreihenfolge, ein Drehbuch (Kapitel je Songabschnitt) und
/// Merkmale mit Regeln (z. B. Tageszeit läuft vorwärts). Ohne Kapitel und ohne Werte schneidet die Engine wie 0.3.0.
public struct Story: Codable, Sendable, Equatable {
    /// Reihenfolge = Erzählreihenfolge.
    public var chapters: [Chapter]
    /// Abschnitts-ID → Kapitel-ID → Rolle. Ein Abschnitt ohne Eintrag ist frei.
    public var plan: [String: [String: ChapterRole]]
    public var traits: [Trait]
    /// Abschnitte, die nicht in der Geschichte vorankommen; `nil` = Refrain-Familien.
    public var montage: Set<String>?
    /// Zeilentext → `true` „braucht ein Bild“, `false` „Bild egal“ (Drehliste).
    public var lineNeeds: [String: Bool]
    /// Stil-Vorlage für Prompts der Drehliste.
    public var promptStyle: String
    /// Banner „Kapitel anlegen“ nach dem ersten Schnitt.
    public var asksForChapters: Bool
    /// Wort-Treffer: Lautwort → Motiv; `nil` = aus.
    public var soundWords: [String: String]?

    public init(
        chapters: [Chapter] = [], plan: [String: [String: ChapterRole]] = [:], traits: [Trait] = [.timeOfDay],
        montage: Set<String>? = nil
    ) {
        self.chapters = chapters
        self.plan = plan
        self.traits = traits
        self.montage = montage
        self.lineNeeds = [:]
        self.promptStyle = ""
        self.asksForChapters = true
        self.soundWords = nil
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chapters = try c.decode(.chapters, default: [])
        plan = try c.decode(.plan, default: [:])
        traits = try c.decode(.traits, default: [.timeOfDay])
        montage = try c.decodeIfPresent(Set<String>.self, forKey: .montage)
        lineNeeds = try c.decode(.lineNeeds, default: [:])
        promptStyle = try c.decode(.promptStyle, default: "")
        asksForChapters = try c.decode(.asksForChapters, default: true)
        soundWords = try c.decodeIfPresent([String: String].self, forKey: .soundWords)
    }

    public func chapter(withID id: String?) -> Chapter? {
        id.flatMap { id in chapters.first { $0.id == id } }
    }

    /// Lautwörter und ihre Motive für Wort-Treffer.
    public static let standardSoundWords: [String: String] = [
        "mäh": "Schaf", "muh": "Kuh", "oink": "Schwein", "grunz": "Schwein", "gack": "Huhn", "kikeriki": "Hahn",
        "quak": "Ente", "iah": "Esel", "wieher": "Pferd", "meck": "Ziege", "schnatter": "Gans", "piep": "Küken",
        "wau": "Hund", "miau": "Katze",
    ]
}

public struct Chapter: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    /// Index in die Kapitel-Farbpalette.
    public var color: Int
    /// Merkmal-ID → Vorgabe, z. B. `["tageszeit": "Abend"]`.
    public var traits: [String: String]

    public init(id: String, name: String, color: Int, traits: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.color = color
        self.traits = traits
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(.name, default: "")
        color = try c.decode(.color, default: 0)
        traits = try c.decode(.traits, default: [:])
    }
}

/// ● Hauptkapitel, ◐ Beimischung.
public enum ChapterRole: String, Codable, Sendable, CaseIterable {
    case main, mix
}

/// Eigenschaft eines Clips mit geordneten Werten und Regel.
public struct Trait: Codable, Sendable, Equatable, Identifiable {
    public enum Rule: String, Codable, Sendable, CaseIterable {
        /// Werte nur vorwärts entlang des Schnitts.
        case progressive
        /// Innerhalb eines Abschnitts kein Zurückwechseln.
        case blockwise
        case off
    }

    public let id: String
    public var name: String
    public var values: [String]
    public var rule: Rule
    /// Abschnitts-ID → festgelegter Wert.
    public var pinned: [String: String]

    public init(id: String, name: String, values: [String], rule: Rule, pinned: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.values = values
        self.rule = rule
        self.pinned = pinned
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(.name, default: id)
        values = try c.decode(.values, default: [])
        rule = try c.decode(.rule, default: .off)
        pinned = try c.decode(.pinned, default: [:])
    }

    public static let timeOfDay = Trait(
        id: "tageszeit", name: "Tageszeit", values: ["Tag", "Abend", "Nacht"], rule: .progressive)

    /// Stufe eines Werts (Index in `values`).
    public func level(_ value: String?) -> Int? {
        value.flatMap { values.firstIndex(of: $0) }
    }
}

/// Wert eines Merkmals mit Herkunft.
public struct TraitValue: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case user, fileName, description
    }

    public var value: String
    public var source: Source

    public init(value: String, source: Source) {
        self.value = value
        self.source = source
    }
}

/// Zeitbereich im Quellclip in Sekunden, z. B. ein Sperrbereich.
public struct SourceRange: Codable, Sendable, Equatable, Hashable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    /// Echte Überschneidung mit `[from, to)`; Berühren zählt nicht.
    public func overlaps(_ from: Double, _ to: Double) -> Bool {
        from < end - 1e-9 && to > start + 1e-9
    }
}

extension [SourceRange] {
    /// Auf `[0, length]` begrenzt, sortiert, überlappende und berührende Bereiche zusammengeführt, leere entfernt.
    public func normalized(length: Double) -> [SourceRange] {
        var result: [SourceRange] = []
        for range in map({ SourceRange(start: Swift.max(0, $0.start), end: Swift.min(length, $0.end)) })
            .filter({ $0.end > $0.start }).sorted(by: { $0.start < $1.start })
        {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1].end = Swift.max(last.end, range.end)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
