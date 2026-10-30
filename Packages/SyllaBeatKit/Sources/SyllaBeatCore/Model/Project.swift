import Foundation

/// Projekt im Format v2. Werttyp: Ein Schnappschuss zum Sichern oder für Undo kostet fast nichts.
///
/// Fehlende Schlüssel erhalten beim Lesen Standardwerte. So öffnen spätere Versionen von 0.3 auch Dateien
/// aus früheren Meilensteinen, und unbekannte Schlüssel aus neueren Dateien werden ignoriert.
public struct Project: Codable, Sendable, Equatable {
    public static let formatVersion = 3

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
    /// Kapitel, Drehbuch und Merkmale; leer heißt: Schnitt wie 0.3.0.
    public var story: Story
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
        self.story = Story()
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
        story = try c.decode(.story, default: Story())
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

extension TimelineSettings {
    public struct Preset: Sendable, Equatable {
        public var title: String
        public var width: Int
        public var height: Int
    }

    /// Format-Vorlagen wie in 0.1.
    public static let presets: [Preset] = [
        Preset(title: "Full HD", width: 1920, height: 1080), Preset(title: "4K", width: 3840, height: 2160),
        Preset(title: "720p", width: 1280, height: 720), Preset(title: "Hochformat 9:16", width: 1080, height: 1920),
        Preset(title: "Quadrat", width: 1080, height: 1080), Preset(title: "Kino 2,39:1", width: 1920, height: 804),
    ]

    /// Wählbare Bildraten.
    public static let rates: [Rational] = [
        Rational(24000, 1001), Rational(24), Rational(25), Rational(30000, 1001), Rational(30), Rational(50),
        Rational(60000, 1001), Rational(60),
    ]

    enum Orientation { case landscape, portrait, square }

    static func orientation(width: Int, height: Int) -> Orientation {
        width == height ? .square : width > height ? .landscape : .portrait
    }

    /// Bildrate lesbar: „25“, „29,97“, „23,976“.
    static func rateText(_ rate: Rational) -> String {
        if rate.denominator == 1 { return "\(rate.numerator)" }
        var text = String(format: "%.3f", rate.doubleValue)
        while text.hasSuffix("0") { text.removeLast() }
        return text.replacingOccurrences(of: ".", with: ",")
    }

    /// Hinweis für das Banner, wenn das Material besser zu einem anderen Format passt; `nil`, wenn alles passt.
    public static func hint(for clips: [Clip], current: TimelineSettings) -> String? {
        let suggested = suggested(for: clips, current: current)
        guard suggested != current else { return nil }
        if suggested.fps == current.fps {
            return suggested.height > suggested.width
                ? "Die meisten Clips sind im Hochformat, die Timeline ist quer."
                : "Die meisten Clips passen nicht zum Seitenverhältnis der Timeline."
        }
        let usable = clips.filter { !$0.excluded && $0.meta.duration > 0 }
        let matching = usable.filter { $0.meta.fps == suggested.fps }.count
        let source = rateText(suggested.fps)
        let target = rateText(current.fps)
        var text = "\(matching) von \(usable.count) Clips haben \(source) fps, die Timeline \(target) fps."
        let a = suggested.fps.doubleValue
        let b = current.fps.doubleValue
        let ordinals = [2: "zweite", 3: "dritte", 4: "vierte", 5: "fünfte", 6: "sechste", 7: "siebte", 8: "achte"]
        if a > b, let word = ordinals[Int((a / (a - b)).rounded())], abs(a / (a - b) - (a / (a - b)).rounded()) < 0.01 {
            text += " Bei \(target) fps fällt jedes \(word) Bild weg."
        } else if a > b {
            text += " Bewegungen können ruckeln."
        } else {
            text += " Einzelne Bilder werden doppelt gezeigt."
        }
        return text
    }

    /// Vorschlag aus dem Material: Bildrate mit der größten Gesamtdauer, Format passend zur Mehrheitsausrichtung
    /// (nach Drehung). Passt die Ausrichtung schon, bleibt die Größe; die Bildanpassung bleibt immer.
    public static func suggested(for clips: [Clip], current: TimelineSettings) -> TimelineSettings {
        var result = current
        let usable = clips.filter { !$0.excluded && $0.meta.duration > 0 }
        guard !usable.isEmpty else { return result }
        var durations: [Rational: Double] = [:]
        for clip in usable { durations[clip.meta.fps, default: 0] += clip.meta.duration }
        if let rate = durations.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key {
            result.fps = rate
        }
        var counts: [Orientation: Int] = [:]
        for clip in usable {
            let size = clip.meta.displaySize
            counts[orientation(width: size.width, height: size.height), default: 0] += 1
        }
        let majority = counts.max { $0.value < $1.value }?.key ?? .landscape
        if orientation(width: current.width, height: current.height) != majority {
            switch majority {
            case .landscape: (result.width, result.height) = (1920, 1080)
            case .portrait: (result.width, result.height) = (1080, 1920)
            case .square: (result.width, result.height) = (1080, 1080)
            }
        }
        return result
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
