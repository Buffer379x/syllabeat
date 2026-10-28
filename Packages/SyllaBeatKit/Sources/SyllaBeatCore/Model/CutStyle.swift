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

    public var preset: Preset
    public var verseBeats: Int
    public var chorusBeats: Int
    public var variation: Variation
    public var chorusFaster: Bool
    public var seed: UInt64

    public init(preset: Preset = .balanced, seed: UInt64 = 1) {
        self.preset = preset
        self.verseBeats = preset.beats.verse
        self.chorusBeats = preset.beats.chorus
        self.variation = preset.variation
        self.chorusFaster = true
        self.seed = seed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decode(.preset, default: .balanced)
        verseBeats = try c.decode(.verseBeats, default: preset.beats.verse)
        chorusBeats = try c.decode(.chorusBeats, default: preset.beats.chorus)
        variation = try c.decode(.variation, default: preset.variation)
        chorusFaster = try c.decode(.chorusFaster, default: true)
        seed = try c.decode(.seed, default: 1)
    }
}
