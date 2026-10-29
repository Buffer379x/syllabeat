import Foundation

/// Projekt im Format v2. Werttyp: Ein Schnappschuss zum Sichern oder für Undo kostet fast nichts.
///
/// Fehlende Schlüssel erhalten beim Lesen Standardwerte. So öffnen spätere Versionen von 0.3 auch Dateien
/// aus früheren Meilensteinen, und unbekannte Schlüssel aus neueren Dateien werden ignoriert.
public struct Project: Codable, Sendable, Equatable {
    public static let formatVersion = 2

    public var version: Int
    public var name: String
    public var timeline: TimelineSettings
    public var song: MediaRef?
    public var lyricsText: String
    /// Regieanweisung für die KI, z. B. „Liebesgeschichte am Meer“.
    public var brief: String
    public var clips: [Clip]
    public var analysis: SongAnalysis?
    /// KI-Regie (Stufe 1); `nil` heißt: Schnitt ohne Storyboard.
    public var storyboard: Storyboard?
    public var style: CutStyle
    /// Aktive Schnittvariante.
    public var cut: Cut?
    public var variants: [Cut]
    /// Herkunft aus 0.2.0, falls migriert.
    public var legacy: LegacyInfo?

    public init(
        name: String = "Neues Musikvideo", timeline: TimelineSettings = TimelineSettings(), song: MediaRef? = nil,
        lyricsText: String = "", brief: String = "", clips: [Clip] = [], analysis: SongAnalysis? = nil,
        style: CutStyle = CutStyle(), cut: Cut? = nil, variants: [Cut] = [], legacy: LegacyInfo? = nil
    ) {
        self.version = Self.formatVersion
        self.name = name
        self.timeline = timeline
        self.song = song
        self.lyricsText = lyricsText
        self.brief = brief
        self.clips = clips
        self.analysis = analysis
        self.storyboard = nil
        self.style = style
        self.cut = cut
        self.variants = variants
        self.legacy = legacy
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        name = try c.decode(.name, default: "Neues Musikvideo")
        timeline = try c.decode(.timeline, default: TimelineSettings())
        song = try c.decodeIfPresent(MediaRef.self, forKey: .song)
        lyricsText = try c.decode(.lyricsText, default: "")
        brief = try c.decode(.brief, default: "")
        clips = try c.decode(.clips, default: [])
        analysis = try c.decodeIfPresent(SongAnalysis.self, forKey: .analysis)
        storyboard = try c.decodeIfPresent(Storyboard.self, forKey: .storyboard)
        style = try c.decode(.style, default: CutStyle())
        cut = try c.decodeIfPresent(Cut.self, forKey: .cut)
        variants = try c.decode(.variants, default: [])
        legacy = try c.decodeIfPresent(LegacyInfo.self, forKey: .legacy)
    }

    public func clip(withID id: String) -> Clip? {
        clips.first { $0.id == id }
    }
}

public struct TimelineSettings: Codable, Sendable, Equatable {
    /// Wie Clips mit anderem Seitenverhältnis ins Format kommen: füllen (Ränder beschnitten) oder einpassen (Balken).
    public enum Fit: String, Codable, Sendable, CaseIterable {
        case fill, fit

        public var title: String {
            switch self {
            case .fill: "Füllen"
            case .fit: "Einpassen"
            }
        }
    }

    public var fps: Rational
    public var width: Int
    public var height: Int
    public var fit: Fit

    public init(fps: Rational = Rational(25), width: Int = 1920, height: Int = 1080, fit: Fit = .fill) {
        self.fps = fps
        self.width = width
        self.height = height
        self.fit = fit
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fps = try c.decode(Rational.self, forKey: .fps)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        fit = try c.decode(.fit, default: .fill)
    }
}

/// Verweis auf eine Mediendatei: Pfad, Bookmark (findet verschobene Dateien) und Fingerprint.
public struct MediaRef: Codable, Sendable, Equatable {
    public var path: String
    public var bookmark: Data?
    /// Größe plus SHA-256 der ersten und letzten 128 KiB, wie in 0.2.0.
    public var fingerprint: String?

    public init(path: String, bookmark: Data? = nil, fingerprint: String? = nil) {
        self.path = path
        self.bookmark = bookmark
        self.fingerprint = fingerprint
    }

    public var fileName: String { (path as NSString).lastPathComponent }
}

/// Herkunft eines aus 0.2.0 übernommenen Projekts.
public struct LegacyInfo: Codable, Sendable, Equatable {
    public var sourceVersion: Int
    public var videoFolder: String
    /// Unverarbeiteter KI-Planentwurf aus 0.2.0.
    public var planDraft: String?
    /// Hinweise der Migration, z. B. verworfene Werte.
    public var notes: [String]

    public init(sourceVersion: Int, videoFolder: String = "", planDraft: String? = nil, notes: [String] = []) {
        self.sourceVersion = sourceVersion
        self.videoFolder = videoFolder
        self.planDraft = planDraft
        self.notes = notes
    }
}

extension KeyedDecodingContainer {
    func decode<T: Decodable>(_ key: Key, default value: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? value()
    }
}
