import Foundation

public struct Clip: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var media: MediaRef
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

    public init(
        id: String, media: MediaRef, meta: ClipMetadata, scenes: [ClipScene] = [], description: String = "",
        tags: [String] = [], mood: String? = nil, rating: Int? = nil, excluded: Bool = false,
        visionModel: String? = nil, filenameSuggestion: String? = nil, originalName: String? = nil
    ) {
        self.id = id
        self.media = media
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
    }

    public var name: String { media.fileName }
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
    public var warnings: [String]

    public init(
        duration: Double, fps: Rational, frameCount: Int64? = nil, width: Int, height: Int, rotation: Int = 0,
        codec: String? = nil, startTimecode: String? = nil, isVFR: Bool? = nil, sizeBytes: Int64? = nil,
        warnings: [String] = []
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

    public init(id: String, start: Double, end: Double, keyframeTime: Double? = nil, description: String = "") {
        self.id = id
        self.start = start
        self.end = end
        self.keyframeTime = keyframeTime
        self.description = description
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        keyframeTime = try c.decodeIfPresent(Double.self, forKey: .keyframeTime)
        description = try c.decode(.description, default: "")
    }
}
