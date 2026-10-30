import Foundation

public struct Clip: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var media: MediaRef
    /// Originaldatei, wenn `media` eine Arbeitskopie ist (MKV, VFR …).
    public var original: MediaRef?
    public var meta: ClipMetadata
    public var scenes: [ClipScene]
    public var description: String
    public var tags: [String]
    public var mood: String?
    public var rating: Int?
    /// „Nie verwenden“.
    public var excluded: Bool
    public var visionModel: String?
    public var filenameSuggestion: String?
    public var originalName: String?
    /// Kapitel der Geschichte.
    public var chapterID: String?
    /// Merkmal-ID → Wert mit Herkunft (Nutzer, Dateiname, Beschreibung).
    public var traits: [String: TraitValue]
    /// Sperrbereiche (KI-Fehler): werden nie verwendet.
    public var blocked: [SourceRange]

    public init(
        id: String, media: MediaRef, original: MediaRef? = nil, meta: ClipMetadata, scenes: [ClipScene] = [],
        description: String = "",
        tags: [String] = [], mood: String? = nil, rating: Int? = nil, excluded: Bool = false,
        visionModel: String? = nil, filenameSuggestion: String? = nil, originalName: String? = nil,
        chapterID: String? = nil, traits: [String: TraitValue] = [:], blocked: [SourceRange] = []
    ) {
        self.chapterID = chapterID
        self.traits = traits
        self.blocked = blocked
        self.id = id
        self.media = media
        self.original = original
        self.meta = meta
        self.scenes = scenes
        self.description = description
        self.tags = tags
        self.mood = mood
        self.rating = rating
        self.excluded = excluded
        self.visionModel = visionModel
        self.filenameSuggestion = filenameSuggestion
        self.originalName = originalName
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        media = try c.decode(MediaRef.self, forKey: .media)
        original = try c.decodeIfPresent(MediaRef.self, forKey: .original)
        meta = try c.decode(ClipMetadata.self, forKey: .meta)
        scenes = try c.decode(.scenes, default: [])
        description = try c.decode(.description, default: "")
        tags = try c.decode(.tags, default: [])
        mood = try c.decodeIfPresent(String.self, forKey: .mood)
        rating = try c.decodeIfPresent(Int.self, forKey: .rating)
        excluded = try c.decode(.excluded, default: false)
        visionModel = try c.decodeIfPresent(String.self, forKey: .visionModel)
        filenameSuggestion = try c.decodeIfPresent(String.self, forKey: .filenameSuggestion)
        originalName = try c.decodeIfPresent(String.self, forKey: .originalName)
        chapterID = try c.decodeIfPresent(String.self, forKey: .chapterID)
        traits = try c.decode(.traits, default: [:])
        blocked = try c.decode(.blocked, default: [])
    }

    public var name: String { (original ?? media).fileName }

    /// Übernimmt eine neue Analyse, behält aber alles, was der Nutzer oder ein Modell eingetragen hat:
    /// Beschreibung, Schlagwörter, Stimmung, Bewertung, Ausschluss, Kapitel, Sperrbereiche, Merkmale von Nutzer oder
    /// Beschreibung und Szenenbeschreibungen gleicher Szenen.
    public func mergingAnalysis(_ fresh: Clip) -> Clip {
        var result = fresh
        result.description = description.isEmpty ? fresh.description : description
        result.tags = tags.isEmpty ? fresh.tags : tags
        result.mood = mood ?? fresh.mood
        result.rating = rating
        result.excluded = excluded
        result.visionModel = visionModel ?? fresh.visionModel
        result.filenameSuggestion = filenameSuggestion ?? fresh.filenameSuggestion
        result.originalName = originalName ?? fresh.originalName
        for index in result.scenes.indices {
            let scene = result.scenes[index]
            if let old = scenes.first(where: { abs($0.start - scene.start) < 0.25 && abs($0.end - scene.end) < 0.25 }),
                !old.description.isEmpty
            {
                result.scenes[index].description = old.description
            }
        }
        return Clip(
            id: id, media: result.media, original: result.original, meta: result.meta, scenes: result.scenes,
            description: result.description, tags: result.tags, mood: result.mood, rating: result.rating,
            excluded: result.excluded, visionModel: result.visionModel,
            filenameSuggestion: result.filenameSuggestion, originalName: result.originalName, chapterID: chapterID,
            traits: traits.filter { $0.value.source != .fileName }, blocked: blocked)
    }
}

public struct ClipMetadata: Codable, Sendable, Equatable {
    public var duration: Double
    public var fps: Rational
    /// Anzahl der Quellframes, falls bekannt.
    public var frameCount: Int64?
    public var width: Int
    public var height: Int
    /// Drehung im Uhrzeigersinn: 0, 90, 180 oder 270.
    public var rotation: Int
    public var codec: String?
    /// Start-Timecode der Kamera, z. B. `10:00:00:00`.
    public var startTimecode: String?
    /// `nil` heißt: nicht geprüft.
    public var isVFR: Bool?
    public var sizeBytes: Int64?
    public var hasAudio: Bool?
    /// AVFoundation kann die Datei nicht lesen; eine Arbeitskopie (ffmpeg) ist nötig.
    public var needsConversion: Bool
    public var warnings: [String]

    public init(
        duration: Double, fps: Rational, frameCount: Int64? = nil, width: Int, height: Int, rotation: Int = 0,
        codec: String? = nil, startTimecode: String? = nil, isVFR: Bool? = nil, sizeBytes: Int64? = nil,
        hasAudio: Bool? = nil, needsConversion: Bool = false, warnings: [String] = []
    ) {
        self.duration = duration
        self.fps = fps
        self.frameCount = frameCount
        self.width = width
        self.height = height
        self.rotation = rotation
        self.codec = codec
        self.startTimecode = startTimecode
        self.isVFR = isVFR
        self.sizeBytes = sizeBytes
        self.hasAudio = hasAudio
        self.needsConversion = needsConversion
        self.warnings = warnings
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        duration = try c.decode(Double.self, forKey: .duration)
        fps = try c.decode(Rational.self, forKey: .fps)
        frameCount = try c.decodeIfPresent(Int64.self, forKey: .frameCount)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        rotation = try c.decode(.rotation, default: 0)
        codec = try c.decodeIfPresent(String.self, forKey: .codec)
        startTimecode = try c.decodeIfPresent(String.self, forKey: .startTimecode)
        isVFR = try c.decodeIfPresent(Bool.self, forKey: .isVFR)
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio)
        needsConversion = try c.decode(.needsConversion, default: false)
        warnings = try c.decode(.warnings, default: [])
    }

    /// Größe nach Anwendung der Drehung.
    public var displaySize: (width: Int, height: Int) {
        rotation % 180 == 0 ? (width, height) : (height, width)
    }

    /// Sicher verfügbare Quelllänge: Dauer, begrenzt durch die Frameanzahl (wie 0.2.0).
    public var availableSeconds: Rational {
        let fromDuration = Rational(seconds: duration)
        guard let frameCount, frameCount > 0 else { return fromDuration }
        return min(fromDuration, Rational(frameCount, 1) / fps)
    }
}

/// Zusammenhängender Abschnitt eines Clips ohne harten Schnitt.
public struct ClipScene: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var start: Double
    public var end: Double
    public var keyframeTime: Double?
    public var description: String
    /// Merkmale aus Apple Vision und der Szenenerkennung; `nil`, solange nicht analysiert.
    public var features: SceneFeatures?
    /// Teil einer langen Einstellung (5-s-Teilung) ohne echten Schnitt zum Vorgänger: Ein Shot darf hinüberreichen.
    public var continuesPrevious: Bool

    public init(
        id: String, start: Double, end: Double, keyframeTime: Double? = nil, description: String = "",
        features: SceneFeatures? = nil, continuesPrevious: Bool = false
    ) {
        self.continuesPrevious = continuesPrevious
        self.id = id
        self.start = start
        self.end = end
        self.keyframeTime = keyframeTime
        self.description = description
        self.features = features
    }

    public var duration: Double { end - start }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        keyframeTime = try c.decodeIfPresent(Double.self, forKey: .keyframeTime)
        description = try c.decode(.description, default: "")
        features = try c.decodeIfPresent(SceneFeatures.self, forKey: .features)
        continuesPrevious = try c.decode(.continuesPrevious, default: false)
    }
}

/// Einstellungsgröße aus der Gesichtsgröße.
public enum ShotSize: String, Codable, Sendable, CaseIterable {
    case closeUp, medium, wide

    public var title: String {
        switch self {
        case .closeUp: "Nah"
        case .medium: "Halbnah"
        case .wide: "Totale"
        }
    }

    /// Fläche des größten Gesichts relativ zum Bild: ab 8 % nah, ab 1,5 % halbnah, sonst Totale.
    public init(largestFaceArea: Double) {
        self = largestFaceArea >= 0.08 ? .closeUp : largestFaceArea >= 0.015 ? .medium : .wide
    }
}

public struct SceneFeatures: Codable, Sendable, Equatable {
    /// Ästhetik-Bewertung von Apple Vision, −1…1.
    public var aesthetics: Double?
    /// Bildschirmfoto, Dokument o. Ä. statt Filmbild.
    public var isUtility: Bool
    /// Stärkste Bildklassen (englische Vision-Bezeichner), absteigend.
    public var labels: [String]
    public var faceCount: Int
    public var shotSize: ShotSize
    /// Laplace-Varianz des verkleinerten Keyframes; klein heißt unscharf.
    public var sharpness: Double
    /// Mittlere Helligkeit 0…1.
    public var brightness: Double
    /// Mittlere Bilddifferenz zwischen Stichproben 0…1.
    public var motion: Double
    /// Dominante Farben als `#RRGGBB`.
    public var colors: [String]

    public init(
        aesthetics: Double? = nil, isUtility: Bool = false, labels: [String] = [], faceCount: Int = 0,
        shotSize: ShotSize = .wide, sharpness: Double = 0, brightness: Double = 0, motion: Double = 0,
        colors: [String] = []
    ) {
        self.aesthetics = aesthetics
        self.isUtility = isUtility
        self.labels = labels
        self.faceCount = faceCount
        self.shotSize = shotSize
        self.sharpness = sharpness
        self.brightness = brightness
        self.motion = motion
        self.colors = colors
    }
}
