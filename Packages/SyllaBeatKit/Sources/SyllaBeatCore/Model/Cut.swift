import Foundation

/// Eine Schnittvariante: lückenlose Folge von Shots vom Songanfang bis zum Songende.
public struct Cut: Codable, Sendable, Equatable, Identifiable {
    public enum Origin: String, Codable, Sendable {
        /// Aus dem Schnittplan von 0.2.0 übernommen.
        case legacyPlan
        case engine
        case manual
    }

    public let id: String
    public var name: String
    public var seed: UInt64
    public var origin: Origin
    public var shots: [Shot]

    public init(id: String, name: String, seed: UInt64, origin: Origin, shots: [Shot]) {
        self.id = id
        self.name = name
        self.seed = seed
        self.origin = origin
        self.shots = shots
    }
}

public struct Shot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var start: CutPoint
    public var end: CutPoint
    public var clipID: String
    public var sceneID: String?
    /// Quell-In in Sekunden, exakt.
    public var sourceIn: Rational
    /// Fixierte Shots bleiben bei jedem Neuberechnen unverändert.
    public var locked: Bool
    /// „Warum dieser Clip?“: Anteile der Bewertung und die besten Alternativen.
    public var reasons: ShotReasons?

    public init(
        id: String, start: CutPoint, end: CutPoint, clipID: String, sceneID: String? = nil, sourceIn: Rational,
        locked: Bool = false, reasons: ShotReasons? = nil
    ) {
        self.reasons = reasons
        self.id = id
        self.start = start
        self.end = end
        self.clipID = clipID
        self.sceneID = sceneID
        self.sourceIn = sourceIn
        self.locked = locked
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        start = try c.decode(CutPoint.self, forKey: .start)
        end = try c.decode(CutPoint.self, forKey: .end)
        clipID = try c.decode(String.self, forKey: .clipID)
        sceneID = try c.decodeIfPresent(String.self, forKey: .sceneID)
        sourceIn = try c.decode(Rational.self, forKey: .sourceIn)
        locked = try c.decode(.locked, default: false)
        reasons = try c.decodeIfPresent(ShotReasons.self, forKey: .reasons)
    }

    public var duration: Double { end.time - start.time }
}

/// Bewertung eines Shots, für den Inspektor.
public struct ShotReasons: Codable, Sendable, Equatable {
    public struct Alternative: Codable, Sendable, Equatable {
        public var clipID: String
        public var sceneID: String
        public var sourceIn: Rational
        public var score: Double

        public init(clipID: String, sceneID: String, sourceIn: Rational, score: Double) {
            self.clipID = clipID
            self.sceneID = sceneID
            self.sourceIn = sourceIn
            self.score = score
        }
    }

    /// Anteile je Kriterium (Schlüssel siehe `CutEngine.Component`), Summe = `total`.
    public var components: [String: Double]
    public var total: Double
    public var alternatives: [Alternative]
    /// Kopie aus der Vorlage einer Wiederholung (Refrain identisch).
    public var copiedFrom: String?
    /// Regeln der Geschichte, die für diesen Shot gelockert wurden (z. B. „kapitel“ bei Materialmangel).
    public var relaxed: [String]

    public init(
        components: [String: Double], total: Double, alternatives: [Alternative], copiedFrom: String? = nil,
        relaxed: [String] = []
    ) {
        self.components = components
        self.total = total
        self.alternatives = alternatives
        self.copiedFrom = copiedFrom
        self.relaxed = relaxed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        components = try c.decode(.components, default: [:])
        total = try c.decode(.total, default: 0)
        alternatives = try c.decode(.alternatives, default: [])
        copiedFrom = try c.decodeIfPresent(String.self, forKey: .copiedFrom)
        relaxed = try c.decode(.relaxed, default: [])
    }
}

/// Schnittgrenze mit Zeit und Anker. Wird das Beat-Raster verschoben, wandern verankerte Schnitte mit.
public struct CutPoint: Codable, Sendable, Hashable {
    public var time: Double
    public var anchor: Anchor

    public init(time: Double, anchor: Anchor) {
        self.time = time
        self.anchor = anchor
    }
}

/// Worauf ein Schnittpunkt verweist. In JSON als kurzer Text: `beat:12`, `word:w7`, `songStart`.
public enum Anchor: Sendable, Hashable, CustomStringConvertible {
    case songStart
    case songEnd
    /// Index in `SongAnalysis.beats`.
    case beat(Int)
    case word(String)
    case syllable(String)
    case section(String)
    case free

    public var description: String {
        switch self {
        case .songStart: "songStart"
        case .songEnd: "songEnd"
        case .beat(let index): "beat:\(index)"
        case .word(let id): "word:\(id)"
        case .syllable(let id): "syllable:\(id)"
        case .section(let id): "section:\(id)"
        case .free: "free"
        }
    }

    public init?(_ text: String) {
        switch text {
        case "songStart": self = .songStart
        case "songEnd": self = .songEnd
        case "free": self = .free
        default:
            guard let colon = text.firstIndex(of: ":") else { return nil }
            let value = String(text[text.index(after: colon)...])
            switch text[..<colon] {
            case "beat":
                guard let index = Int(value), index >= 0 else { return nil }
                self = .beat(index)
            case "word" where !value.isEmpty: self = .word(value)
            case "syllable" where !value.isEmpty: self = .syllable(value)
            case "section" where !value.isEmpty: self = .section(value)
            default: return nil
            }
        }
    }
}

extension Anchor: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let anchor = Anchor(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unbekannter Anker „\(text)“")
        }
        self = anchor
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
