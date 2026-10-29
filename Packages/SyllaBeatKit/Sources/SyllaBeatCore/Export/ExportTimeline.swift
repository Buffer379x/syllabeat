import Foundation

/// Was ein Export zusätzlich zur Frame-Tabelle mitnimmt.
public struct ExportOptions: Sendable, Equatable {
    /// Wo der Song in FCPXML liegt (F11): verbunden mit dem ersten Clip (wie 0.2.0) oder als Primärhandlung.
    public enum SongPlacement: String, Sendable, CaseIterable {
        case connected, primary

        public var title: String {
            switch self {
            case .connected: "Verbunden mit dem ersten Clip"
            case .primary: "Als Primärhandlung"
            }
        }
    }

    public var sectionMarkers: Bool
    public var lineMarkers: Bool
    public var barMarkers: Bool
    /// Schlagwörter und Beschreibungen der Clips als Keywords und Notizen.
    public var keywords: Bool
    public var songPlacement: SongPlacement

    public init(
        sectionMarkers: Bool = true, lineMarkers: Bool = true, barMarkers: Bool = false, keywords: Bool = true,
        songPlacement: SongPlacement = .connected
    ) {
        self.sectionMarkers = sectionMarkers
        self.lineMarkers = lineMarkers
        self.barMarkers = barMarkers
        self.keywords = keywords
        self.songPlacement = songPlacement
    }

    /// Genau wie 0.2.0 (für die Golden-Tests): ohne Marker und Schlagwörter, Song verbunden.
    public static let legacy = ExportOptions(
        sectionMarkers: false, lineMarkers: false, barMarkers: false, keywords: false, songPlacement: .connected)
}

/// Ein Marker in Timeline-Frames.
public struct ExportMarker: Sendable, Equatable {
    public enum Kind: String, Sendable { case section, line, bar }

    public var frame: Int64
    public var name: String
    public var kind: Kind
}

/// Alles, was die Exporter brauchen: die kompilierte Frame-Tabelle (einzige Quelle aller Dauern, I7), die Clips
/// und der Song. Shots heißen `shot-1` … in Timeline-Reihenfolge.
public struct ExportTimeline: Sendable {
    public struct Item: Sendable {
        public var id: String
        public var entry: FrameTable.Entry
        public var clip: Clip
        public var shot: Shot
        /// Anfangs- und Endbeat (für OTIO-Metadaten wie in 0.2.0), sonst `nil`.
        public var startBeat: Int?
        public var endBeat: Int?

        public var sourceRate: Rational { entry.sourceFPS }
        public var name: String { clip.name }

        /// Länge der Quelle in Quellframes: Frame-Anzahl der Datei, sonst Dauer × Rate abgerundet (wie 0.2.0).
        public var sourceFrames: Int64 {
            if let count = clip.meta.frameCount, count > 0 { return count }
            return max(1, FrameMath.floorFrames(seconds: clip.meta.duration, rate: sourceRate))
        }

        /// Start-Timecode der Datei in Quellframes (F2); 0 ohne Timecode.
        public var timecodeStart: Int64 {
            ExportText.frames(ofTimecode: clip.meta.startTimecode, rate: sourceRate) ?? 0
        }
    }

    public struct Song: Sendable {
        public var path: String
        public var duration: Double
        public var sampleRate: Int
        public var channels: Int

        public var name: String { (path as NSString).lastPathComponent }
        /// Kanäle für die Exporte: 1 oder 2.
        public var exportChannels: Int { max(1, min(2, channels)) }
        /// Dauer in Samples, gerundet (wie 0.2.0).
        public var sampleCount: Int64 { Int64((duration * Double(sampleRate)).rounded()) }
    }

    public var name: String
    public var table: FrameTable
    public var items: [Item]
    public var song: Song
    public var analysis: SongAnalysis
    public var markers: [ExportMarker]

    public var rate: Rational { table.fps }
    public var frameDuration: Rational { Rational(1) / table.fps }

    public init(_ project: Project, options: ExportOptions = ExportOptions()) throws {
        guard let cut = project.cut, !cut.shots.isEmpty else { throw ExportError.noCut }
        guard let analysis = project.analysis, let song = project.song else { throw ExportError.noSong }
        let table = try CutCompiler.compile(project, cut: cut)
        let clips = Dictionary(project.clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let beats = analysis.beats.map(\.time)
        func beatIndex(_ point: CutPoint) -> Int? {
            if case .beat(let index) = point.anchor { return index + 1 }
            if case .songStart = point.anchor { return 0 }
            if case .songEnd = point.anchor { return beats.count + 1 }
            return nil
        }
        name = project.name
        self.table = table
        self.analysis = analysis
        items = zip(table.entries, cut.shots).enumerated().map { index, pair in
            Item(
                id: "shot-\(index + 1)", entry: pair.0, clip: clips[pair.0.clipID]!, shot: pair.1,
                startBeat: beatIndex(pair.1.start), endBeat: beatIndex(pair.1.end))
        }
        self.song = Song(
            path: song.path, duration: analysis.duration, sampleRate: analysis.sampleRate,
            channels: analysis.channels)
        markers = Self.markers(analysis, rate: table.fps, end: table.durationFrames, options: options)
    }

    static func markers(
        _ analysis: SongAnalysis, rate: Rational, end: Int64, options: ExportOptions
    )
        -> [ExportMarker]
    {
        var result: [ExportMarker] = []
        func add(_ time: Double, _ name: String, _ kind: ExportMarker.Kind) {
            let frame = FrameMath.frame(atSeconds: max(0, time), rate: rate)
            guard frame < end else { return }
            result.append(ExportMarker(frame: frame, name: name, kind: kind))
        }
        if options.sectionMarkers {
            for section in analysis.sections.sorted(by: { $0.start < $1.start }) {
                add(section.start, section.label, .section)
            }
        }
        if options.lineMarkers {
            for line in analysis.lines where !line.text.isEmpty { add(line.start, line.text, .line) }
        }
        if options.barMarkers {
            var bar = 0
            for beat in analysis.beats where beat.isDownbeat {
                bar += 1
                add(beat.time, "Takt \(bar)", .bar)
            }
        }
        return result.sorted { $0.frame != $1.frame ? $0.frame < $1.frame : $0.kind.rawValue < $1.kind.rawValue }
    }
}

extension FrameMath {
    /// Abgerundete Frames (`math.floor(Fraction(str(duration)) * rate)` in 0.2.0).
    public static func floorFrames(seconds: Double, rate: Rational) -> Int64 {
        let value = Rational(seconds: seconds) * rate
        let quotient = value.numerator / value.denominator
        return value.numerator % value.denominator != 0 && value.numerator < 0 ? quotient - 1 : quotient
    }

    /// Aufgerundete Frames (`math.ceil` in 0.2.0).
    public static func ceilFrames(seconds: Double, rate: Rational) -> Int64 {
        let value = Rational(seconds: seconds) * rate
        let quotient = value.numerator / value.denominator
        return value.numerator % value.denominator != 0 && value.numerator > 0 ? quotient + 1 : quotient
    }
}
