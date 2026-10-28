import Foundation

public struct SongAnalysis: Codable, Sendable, Equatable {
    public var duration: Double
    public var sampleRate: Int
    public var channels: Int
    public var tempo: Double
    /// Schläge pro Takt.
    public var meter: Int
    /// Erkannte Beats, aufsteigend und streng innerhalb von `(0, duration)`.
    public var beats: [Beat]
    public var words: [Word]
    public var lines: [LyricLine]
    public var sections: [SongSection]
    /// Energie pro Beat, normiert auf 0…1.
    public var energy: [Float]
    public var language: String?
    public var transcriptionModel: String?
    public var warnings: [String]

    public init(
        duration: Double, sampleRate: Int = 48000, channels: Int = 2, tempo: Double = 0, meter: Int = 4,
        beats: [Beat] = [], words: [Word] = [], lines: [LyricLine] = [], sections: [SongSection] = [],
        energy: [Float] = [], language: String? = nil, transcriptionModel: String? = nil, warnings: [String] = []
    ) {
        self.duration = duration
        self.sampleRate = sampleRate
        self.channels = channels
        self.tempo = tempo
        self.meter = meter
        self.beats = beats
        self.words = words
        self.lines = lines
        self.sections = sections
        self.energy = energy
        self.language = language
        self.transcriptionModel = transcriptionModel
        self.warnings = warnings
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        duration = try c.decode(Double.self, forKey: .duration)
        sampleRate = try c.decode(.sampleRate, default: 48000)
        channels = try c.decode(.channels, default: 2)
        tempo = try c.decode(.tempo, default: 0)
        meter = try c.decode(.meter, default: 4)
        beats = try c.decode(.beats, default: [])
        words = try c.decode(.words, default: [])
        lines = try c.decode(.lines, default: [])
        sections = try c.decode(.sections, default: [])
        energy = try c.decode(.energy, default: [])
        language = try c.decodeIfPresent(String.self, forKey: .language)
        transcriptionModel = try c.decodeIfPresent(String.self, forKey: .transcriptionModel)
        warnings = try c.decode(.warnings, default: [])
    }

    /// Grenzentabelle wie in 0.2.0: Songanfang, alle Beats, Songende.
    public var boundaries: [Double] { [0] + beats.map(\.time) + [duration] }
}

public struct Beat: Codable, Sendable, Equatable {
    public var time: Double
    public var isDownbeat: Bool
    public var confidence: Double?

    public init(time: Double, isDownbeat: Bool = false, confidence: Double? = nil) {
        self.time = time
        self.isDownbeat = isDownbeat
        self.confidence = confidence
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Double.self, forKey: .time)
        isDownbeat = try c.decode(.isDownbeat, default: false)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
    }
}

public struct Word: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Double?
    /// Zeit wurde geschätzt statt erkannt.
    public var estimated: Bool

    public init(
        id: String, text: String, start: Double, end: Double, confidence: Double? = nil, estimated: Bool = false
    ) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.estimated = estimated
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        estimated = try c.decode(.estimated, default: false)
    }
}

public struct LyricLine: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Double?
    public var needsReview: Bool

    public init(
        id: String, text: String, start: Double, end: Double, confidence: Double? = nil, needsReview: Bool = false
    ) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.needsReview = needsReview
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        needsReview = try c.decode(.needsReview, default: false)
    }
}

public struct SongSection: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case intro, verse, preChorus, chorus, bridge, instrumental, outro, other

        /// Ordnet eine freie Bezeichnung wie „Refrain 2“ oder „Pre-Chorus“ einem Typ zu.
        public init(label: String) {
            let text = label.lowercased()
            func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
            if has("pre-chorus", "prechorus", "pre-refrain", "vorrefrain", "pre chorus") {
                self = .preChorus
            } else if has("refrain", "chorus", "hook") {
                self = .chorus
            } else if has("strophe", "verse", "vers") {
                self = .verse
            } else if has("bridge", "zwischenteil") {
                self = .bridge
            } else if has("intro") {
                self = .intro
            } else if has("outro", "schluss", "ende") {
                self = .outro
            } else if has("instrumental", "solo") {
                self = .instrumental
            } else {
                self = .other
            }
        }
    }

    public let id: String
    public var kind: Kind
    public var label: String
    public var start: Double
    public var end: Double
    /// Vorlage dieser Wiederholung (Familie).
    public var repeatOf: String?
    public var needsReview: Bool

    public init(
        id: String, kind: Kind, label: String, start: Double, end: Double, repeatOf: String? = nil,
        needsReview: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.start = start
        self.end = end
        self.repeatOf = repeatOf
        self.needsReview = needsReview
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(.label, default: "")
        kind = try c.decode(.kind, default: Kind(label: label))
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        repeatOf = try c.decodeIfPresent(String.self, forKey: .repeatOf)
        needsReview = try c.decode(.needsReview, default: false)
    }
}
