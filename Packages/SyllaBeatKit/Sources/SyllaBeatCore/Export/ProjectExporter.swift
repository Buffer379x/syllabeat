import Foundation

/// Exportformate (Plan 6.5).
public enum ExportFormat: String, Sendable, CaseIterable, Identifiable {
    case fcpxml, xmeml, edl, markerEDL, otio, cutList, catalogJSON, catalogCSV, srt, lrc, youtubeChapters

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fcpxml: "Final Cut Pro XML 1.8"
        case .xmeml: "FCP-7-XML (Premiere)"
        case .edl: "CMX-3600-EDL"
        case .markerEDL: "Marker-EDL (Resolve)"
        case .otio: "OpenTimelineIO"
        case .cutList: "Schnittliste (JSON)"
        case .catalogJSON: "Clip-Katalog (JSON)"
        case .catalogCSV: "Clip-Katalog (CSV)"
        case .srt: "Untertitel (SRT)"
        case .lrc: "Songtext mit Zeiten (LRC)"
        case .youtubeChapters: "YouTube-Kapitel (TXT)"
        }
    }

    /// Dateiname im Exportordner.
    public func fileName(base: String) -> String {
        switch self {
        case .fcpxml: "\(base).fcpxml"
        case .xmeml: "\(base).xml"
        case .edl: "\(base).edl"
        case .markerEDL: "\(base) Marker.edl"
        case .otio: "\(base).otio"
        case .cutList: "schnittliste.json"
        case .catalogJSON: "clip-katalog.json"
        case .catalogCSV: "clip-katalog.csv"
        case .srt: "\(base).srt"
        case .lrc: "\(base).lrc"
        case .youtubeChapters: "youtube-kapitel.txt"
        }
    }
}

/// Zielprogramm im Export-Dialog: Die Formate ergeben sich daraus („Erweitert“ zeigt alle).
public enum ExportTarget: String, Sendable, CaseIterable, Identifiable {
    case finalCut, resolve, premiere, archive, video

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .finalCut: "Final Cut Pro"
        case .resolve: "DaVinci Resolve"
        case .premiere: "Adobe Premiere Pro"
        case .archive: "Nur Archiv"
        case .video: "Video (YouTube)"
        }
    }

    public var formats: [ExportFormat] {
        switch self {
        case .finalCut: [.fcpxml, .cutList, .catalogJSON]
        // Resolve 21.1 übernimmt den Song nur aus FCPXML (aus FCP-7-XML kommt nur das Bild, E5); die EDL bleibt als
        // Rückfalloption, die Marker-EDL bringt die Marker.
        case .resolve: [.fcpxml, .edl, .markerEDL, .cutList, .catalogJSON]
        case .premiere: [.xmeml, .cutList, .catalogJSON]
        case .archive: [.cutList, .catalogJSON, .catalogCSV, .otio]
        // Das MP4 und das Vorschaubild schreibt der Renderer (SyllaBeatMedia); hier nur die Textdateien.
        case .video: [.youtubeChapters, .srt]
        }
    }
}

public enum ProjectExporter {
    /// Inhalt eines Formats (ohne zu schreiben).
    public static func content(_ format: ExportFormat, project: Project, options: ExportOptions) throws -> String {
        let timeline = try ExportTimeline(project, options: options)
        return try content(format, timeline: timeline, project: project, options: options)
    }

    static func content(
        _ format: ExportFormat, timeline: ExportTimeline, project: Project, options: ExportOptions
    )
        throws -> String
    {
        switch format {
        case .fcpxml: FCPXMLExporter.document(timeline, options: options)
        case .xmeml: try XMEMLExporter.document(timeline, options: options)
        case .edl: EDLExporter.document(timeline)
        case .markerEDL: EDLExporter.markers(timeline)
        case .otio: try OTIOExporter.document(timeline)
        case .cutList: try ArchiveExporter.cutList(timeline, project: project)
        case .catalogJSON: try ArchiveExporter.catalogJSON(project)
        case .catalogCSV: ArchiveExporter.catalogCSV(project)
        case .srt: SubtitleExporter.srt(timeline.analysis)
        case .lrc: SubtitleExporter.lrc(timeline.analysis, title: timeline.name)
        case .youtubeChapters:
            project.cut.flatMap { YouTubeExport.chapters(project, cut: $0) }
                ?? "Zu wenige Teile für YouTube-Kapitel (YouTube verlangt mindestens drei, je mindestens 10 s).\n"
        }
    }

    /// Fehlende Mediendateien (Clips des Schnitts und Song).
    public static func missingMedia(_ project: Project) -> [String] {
        let used = Set(project.cut?.shots.map(\.clipID) ?? [])
        var paths = project.clips.filter { used.contains($0.id) }.map(\.media.path)
        if let song = project.song?.path { paths.append(song) }
        return paths.filter { !FileManager.default.fileExists(atPath: $0) }
    }

    /// Schreibt alle Formate atomar nach `folder`. Erst wird alles erzeugt, dann geschrieben: Scheitert ein Format,
    /// entsteht keine Datei.
    @discardableResult
    public static func export(
        _ project: Project, formats: [ExportFormat], options: ExportOptions, to folder: URL, baseName: String,
        checkMedia: Bool = true
    ) throws -> [URL] {
        if checkMedia {
            let missing = missingMedia(project)
            guard missing.isEmpty else { throw ExportError.missingMedia(missing) }
        }
        let timeline = try ExportTimeline(project, options: options)
        let contents = try formats.map { format in
            (
                folder.appendingPathComponent(format.fileName(base: baseName)),
                try content(format, timeline: timeline, project: project, options: options)
            )
        }
        for (url, text) in contents { try ExportText.write(text, to: url) }
        return contents.map(\.0)
    }
}
