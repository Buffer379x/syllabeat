import Foundation

/// Schnittstil: Preset plus Regler. Die Regler überschreiben die Werte des Presets.
public struct CutStyle: Codable, Sendable, Equatable {
    public enum Preset: String, Codable, Sendable, CaseIterable {
        case calm, balanced, energetic, hectic

        public var title: String {
            switch self {
            case .calm: "Ruhig"
            case .balanced: "Ausgewogen"
            case .energetic: "Energetisch"
            case .hectic: "Hektisch"
            }
        }

        /// Beats pro Shot in Strophe und Refrain.
        public var beats: (verse: Int, chorus: Int) {
            switch self {
            case .calm: (8, 4)
            case .balanced: (4, 2)
            case .energetic: (2, 1)
            case .hectic: (1, 1)
            }
        }

        public var variation: Variation {
            switch self {
            case .calm: .low
            case .balanced: .medium
            case .energetic, .hectic: .high
            }
        }

        public var minimumDuration: Double {
            switch self {
            case .calm: 1.5
            case .balanced: 0.6
            case .energetic: 0.4
            case .hectic: 0.2
            }
        }

        public var followEnergy: Double {
            switch self {
            case .calm: 0.2
            case .balanced: 0.5
            case .energetic, .hectic: 0.9
            }
        }

        /// Preset, das am besten zu einer Strophenlänge passt.
        public static func nearest(verseBeats: Int) -> Preset {
            switch verseBeats {
            case 8...: .calm
            case 4...: .balanced
            case 2...: .energetic
            default: .hectic
            }
        }
    }

    public enum Variation: String, Codable, Sendable, CaseIterable {
        case low, medium, high
    }

    /// Wie Wiederholungen (Refrains) geschnitten werden.
    public enum RefrainMode: String, Codable, Sendable, CaseIterable {
        /// Exakte Kopie der Vorlage.
        case identical
        /// Gleiche Clips, andere Ausschnitte.
        case sameClips
        /// Unabhängig neu geschnitten.
        case free
        /// Gleiche Motivfolge, aber der jeweils nächste Take (KI-Clips mit mehreren Generierungen).
        case sameMotifs

        public var title: String {
            switch self {
            case .identical: "Identisch"
            case .sameClips: "Gleiche Clips, andere Ausschnitte"
            case .free: "Frei"
            case .sameMotifs: "Gleiche Motive, andere Takes"
            }
        }
    }

    public var preset: Preset
    public var verseBeats: Int
    public var chorusBeats: Int
    public var variation: Variation
    public var chorusFaster: Bool
    public var seed: UInt64
    public var refrainMode: RefrainMode
    /// Kürzeste Einstellung in Sekunden.
    public var minimumDuration: Double
    /// Wie stark die Songenergie die Schnittdichte bestimmt, 0…1.
    public var followEnergy: Double
    /// Schnitte auf Wortanfänge legen, wenn ein Wort nahe am Beat beginnt.
    public var alignToWords: Bool

    public init(preset: Preset = .balanced, seed: UInt64 = 1) {
        self.preset = preset
        self.verseBeats = preset.beats.verse
        self.chorusBeats = preset.beats.chorus
        self.variation = preset.variation
        self.chorusFaster = true
        self.seed = seed
        self.refrainMode = .identical
        self.minimumDuration = preset.minimumDuration
        self.followEnergy = preset.followEnergy
        self.alignToWords = preset != .calm
    }

    /// Übernimmt die Werte eines Presets, behält Seed und Refrain-Modus.
    public func applying(_ preset: Preset) -> CutStyle {
        var style = CutStyle(preset: preset, seed: seed)
        style.refrainMode = refrainMode
        return style
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decode(.preset, default: .balanced)
        verseBeats = try c.decode(.verseBeats, default: preset.beats.verse)
        chorusBeats = try c.decode(.chorusBeats, default: preset.beats.chorus)
        variation = try c.decode(.variation, default: preset.variation)
        chorusFaster = try c.decode(.chorusFaster, default: true)
        seed = try c.decode(.seed, default: 1)
        refrainMode = try c.decode(.refrainMode, default: .identical)
        minimumDuration = try c.decode(.minimumDuration, default: preset.minimumDuration)
        followEnergy = try c.decode(.followEnergy, default: preset.followEnergy)
        alignToWords = try c.decode(.alignToWords, default: preset != .calm)
    }
}
