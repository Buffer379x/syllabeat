import Foundation

/// CMX-3600-EDL, der kleinste gemeinsame Nenner für DaVinci Resolve und andere. Record-Timecode ab 01:00:00:00.
///
/// Korrekturen gegenüber 0.2.0:
/// - F1: Quell-Out = Quell-In + Dauer **in derselben Rate**. Alle Timecodes stehen in der Timeline-Rate (Kopfzeile
///   `FCM`); 0.2.0 mischte Quellframes und Timeline-Frames, bei 50p-Clips in 25p stimmte die Länge nicht.
/// - F2: Quell-Timecode = Start-Timecode der Datei + Quell-In statt immer ab 00:00:00:00.
public enum EDLExporter {
    public static func document(_ timeline: ExportTimeline) -> String {
        let rate = timeline.rate
        let offset = Int64(rate.doubleValue.rounded()) * 3600
        var lines = ["TITLE: \(timeline.name)", "FCM: NON-DROP FRAME", ""]
        for (number, item) in timeline.items.enumerated() {
            let sourceSeconds =
                Rational(item.timecodeStart + item.entry.sourceInFrame) / item.sourceRate
            let sourceIn = FrameMath.frame(at: sourceSeconds, rate: rate)
            let sourceOut = sourceIn + item.entry.durationFrames
            let reel = "AX".padding(toLength: 8, withPad: " ", startingAt: 0)
            lines.append(
                String(format: "%03d", number + 1) + "  \(reel) V     C        "
                    + "\(ExportText.timecode(sourceIn, rate: rate)) \(ExportText.timecode(sourceOut, rate: rate)) "
                    + "\(ExportText.timecode(offset + item.entry.startFrame, rate: rate)) "
                    + "\(ExportText.timecode(offset + item.entry.endFrame, rate: rate))")
            lines.append("* FROM CLIP NAME: \(item.name)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Marker-EDL für Resolve („Zeitleistenmarker aus EDL importieren“): Abschnitte blau, Zeilen grün, Takte grau.
    public static func markers(_ timeline: ExportTimeline) -> String {
        let rate = timeline.rate
        let offset = Int64(rate.doubleValue.rounded()) * 3600
        var lines = ["TITLE: \(timeline.name) – Marker", "FCM: NON-DROP FRAME", ""]
        for (number, marker) in timeline.markers.enumerated() {
            let start = ExportText.timecode(offset + marker.frame, rate: rate)
            let end = ExportText.timecode(offset + marker.frame + 1, rate: rate)
            let color =
                switch marker.kind {
                case .section: "ResolveColorBlue"
                case .line: "ResolveColorGreen"
                case .bar: "ResolveColorCream"
                }
            lines.append(
                String(format: "%03d", number + 1) + "  001      V     C        \(start) \(end) \(start) \(end)  ")
            lines.append(" |C:\(color) |M:\(marker.name.replacingOccurrences(of: "|", with: "/")) |D:1")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

/// OpenTimelineIO (`otio_json`) wie 0.2.0: Spur „Song“ (Audio) und „Video“; Videodauern in Timeline-Zeit, verfügbare
/// Bereiche in Quellzeit. Neu: Marker auf der Videospur.
public enum OTIOExporter {
    static func time(_ value: Double, _ rate: Double) -> [String: Any] {
        ["OTIO_SCHEMA": "RationalTime.1", "rate": rate, "value": value]
    }

    static func range(start: Double, duration: Double, rate: Double) -> [String: Any] {
        ["OTIO_SCHEMA": "TimeRange.1", "start_time": time(start, rate), "duration": time(duration, rate)]
    }

    static func clip(
        name: String, url: String, source: [String: Any], available: [String: Any], metadata: [String: Any]
    )
        -> [String: Any]
    {
        [
            "OTIO_SCHEMA": "Clip.2", "metadata": metadata, "name": name, "source_range": source, "effects": [Any](),
            "markers": [Any](), "enabled": true, "color": NSNull(),
            "media_references": [
                "DEFAULT_MEDIA": [
                    "OTIO_SCHEMA": "ExternalReference.1", "metadata": [String: Any](), "name": "",
                    "available_range": available, "available_image_bounds": NSNull(), "target_url": url,
                ]
            ],
            "active_media_reference_key": "DEFAULT_MEDIA",
        ]
    }

    static func track(
        _ name: String, kind: String, children: [[String: Any]], markers: [[String: Any]] = []
    )
        -> [String: Any]
    {
        [
            "OTIO_SCHEMA": "Track.1", "metadata": [String: Any](), "name": name, "source_range": NSNull(),
            "effects": [Any](), "markers": markers, "enabled": true, "color": NSNull(), "children": children,
            "kind": kind,
        ]
    }

    public static func object(_ timeline: ExportTimeline) -> [String: Any] {
        let fps = timeline.rate.doubleValue
        let song = timeline.song
        let sampleRate = Double(song.sampleRate)
        let songRange = range(start: 0, duration: Double(song.sampleCount), rate: sampleRate)
        let audio = clip(
            name: song.name, url: ExportText.fileURL(song.path), source: songRange, available: songRange, metadata: [:])
        var videoClips: [[String: Any]] = []
        for item in timeline.items {
            let sourceRate = item.sourceRate
            let sourceFPS = Double(sourceRate.numerator) / Double(sourceRate.denominator)
            let sourceStart = Double(item.entry.sourceInFrame) / sourceFPS * fps
            var metadata: [String: Any] = [
                "clip_id": item.clip.id, "source_fps_num": sourceRate.numerator,
                "source_fps_den": sourceRate.denominator,
            ]
            metadata["start_beat"] = item.startBeat ?? NSNull()
            metadata["end_beat"] = item.endBeat ?? NSNull()
            videoClips.append(
                clip(
                    name: item.name, url: ExportText.fileURL(item.clip.media.path),
                    source: range(start: sourceStart, duration: Double(item.entry.durationFrames), rate: fps),
                    available: range(start: 0, duration: Double(item.sourceFrames), rate: sourceFPS),
                    metadata: ["SyllaBeat": metadata]))
        }
        let markers: [[String: Any]] = timeline.markers.map { marker in
            [
                "OTIO_SCHEMA": "Marker.2", "metadata": [String: Any](), "name": marker.name,
                "color": marker.kind == .section ? "BLUE" : marker.kind == .line ? "GREEN" : "WHITE",
                "marked_range": range(start: Double(marker.frame), duration: 0, rate: fps), "comment": "",
            ]
        }
        let rate = timeline.rate
        return [
            "OTIO_SCHEMA": "Timeline.1",
            "metadata": [
                "SyllaBeat": [
                    "fps_num": rate.numerator, "fps_den": rate.denominator, "width": timeline.table.width,
                    "height": timeline.table.height,
                ]
            ],
            "name": timeline.name, "global_start_time": time(0, fps),
            "tracks": [
                "OTIO_SCHEMA": "Stack.1", "metadata": [String: Any](), "name": "tracks", "source_range": NSNull(),
                "effects": [Any](), "markers": [Any](), "enabled": true, "color": NSNull(),
                "children": [
                    track("Song", kind: "Audio", children: [audio]),
                    track("Video", kind: "Video", children: videoClips, markers: markers),
                ],
            ],
        ]
    }

    public static func document(_ timeline: ExportTimeline) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object(timeline), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

/// Archiv (Schema v2): Schnittliste mit Frame-Tabelle und Ankern, Clip-Katalog als JSON und CSV.
public enum ArchiveExporter {
    public static func cutList(_ timeline: ExportTimeline, project: Project) throws -> String {
        let shots: [[String: Any]] = timeline.items.map { item in
            [
                "id": item.id, "clipID": item.clip.id, "name": item.name, "path": item.clip.media.path,
                "startFrame": item.entry.startFrame, "endFrame": item.entry.endFrame,
                "durationFrames": item.entry.durationFrames, "sourceInFrame": item.entry.sourceInFrame,
                "sourceOutFrame": item.entry.sourceOutFrame, "sourceFPS": item.sourceRate.description,
                "start": item.shot.start.anchor.description, "end": item.shot.end.anchor.description,
                "locked": item.shot.locked,
            ]
        }
        let object: [String: Any] = [
            "schema": "syllabeat.cutlist/2", "name": timeline.name, "fps": timeline.rate.description,
            "width": timeline.table.width, "height": timeline.table.height,
            "durationFrames": timeline.table.durationFrames, "song": timeline.song.path,
            "style": project.style.preset.rawValue, "seed": project.cut?.seed ?? 0, "shots": shots,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    public static func catalogJSON(_ project: Project) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(project.clips), as: UTF8.self) + "\n"
    }

    /// CSV mit Semikolon (öffnet sich in deutschem Numbers/Excel direkt in Spalten).
    public static func catalogCSV(_ project: Project) -> String {
        func field(_ text: String) -> String {
            text.contains(";") || text.contains("\"") || text.contains("\n")
                ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        var rows = ["Name;Pfad;Dauer (s);Bildrate;Größe;Beschreibung;Schlagwörter;Stimmung;Bewertung;Im Schnitt"]
        for clip in project.clips {
            rows.append(
                [
                    clip.name, clip.media.path,
                    String(format: "%.3f", clip.meta.duration).replacingOccurrences(of: ".", with: ","),
                    clip.meta.fps.description, "\(clip.meta.width)×\(clip.meta.height)", clip.description,
                    clip.tags.joined(separator: ", "), clip.mood ?? "", clip.rating.map(String.init) ?? "",
                    "\(project.usageCount(of: clip.id))",
                ].map(field).joined(separator: ";"))
        }
        return rows.joined(separator: "\n") + "\n"
    }
}

/// Untertitel aus den ausgerichteten Textzeilen (S-07).
public enum SubtitleExporter {
    public static func srt(_ analysis: SongAnalysis) -> String {
        func stamp(_ seconds: Double) -> String {
            let milliseconds = Int((max(0, seconds) * 1000).rounded())
            return String(
                format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000, milliseconds / 60000 % 60,
                milliseconds / 1000 % 60, milliseconds % 1000)
        }
        return analysis.lines.filter { !$0.text.isEmpty }.enumerated().map { index, line in
            "\(index + 1)\n\(stamp(line.start)) --> \(stamp(max(line.end, line.start + 0.5)))\n\(line.text)\n"
        }.joined(separator: "\n")
    }

    public static func lrc(_ analysis: SongAnalysis, title: String) -> String {
        func stamp(_ seconds: Double) -> String {
            let hundredths = Int((max(0, seconds) * 100).rounded())
            return String(format: "[%02d:%02d.%02d]", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
        }
        let lines = analysis.lines.filter { !$0.text.isEmpty }.map { stamp($0.start) + $0.text }
        return (["[ti:\(title)]"] + lines).joined(separator: "\n") + "\n"
    }
}
