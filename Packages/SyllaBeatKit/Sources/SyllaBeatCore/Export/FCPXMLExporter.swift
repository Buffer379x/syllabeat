import Foundation

/// Final Cut Pro XML 1.8 (wie 0.2.0; Final Cut Pro 12.4 und DaVinci Resolve importieren sie). Die Primärhandlung
/// enthält das Bild, der ganze Song hängt verbunden am ersten Clip, mit Offset in dessen Quellzeit – oder liegt als
/// Primärhandlung unten, mit den Clips verbunden darüber (F11). Neu: Marker für Abschnitte, Zeilen und Takte,
/// Schlagwörter als Keywords, Beschreibungen als Notizen, Start-Timecode der Dateien (F2).
public enum FCPXMLExporter {
    static let appleSizes: [String: String] = ["1920x1080": "1080p", "3840x2160": "2160p", "1280x720": "720p"]
    static let appleRates: [Rational: String] = [
        Rational(24): "24", Rational(25): "25", Rational(30): "30", Rational(50): "50", Rational(60): "60",
        Rational(24000, 1001): "2398", Rational(30000, 1001): "2997", Rational(60000, 1001): "5994",
    ]

    static func format(id: String, rate: Rational, width: Int, height: Int) -> XMLNode {
        var attributes: [(String, String)] = [("id", id)]
        let kind = appleSizes["\(width)x\(height)"]
        if let kind, let suffix = appleRates[rate] { attributes.append(("name", "FFVideoFormat\(kind)\(suffix)")) }
        attributes += [
            ("frameDuration", ExportText.time(Rational(1) / rate)), ("width", "\(width)"), ("height", "\(height)"),
        ]
        if kind != nil { attributes.append(("colorSpace", "1-1-1 (Rec. 709)")) }
        return XMLNode("format", attributes)
    }

    public static func document(_ timeline: ExportTimeline, options: ExportOptions = ExportOptions()) -> String {
        let rate = timeline.rate
        let frame = timeline.frameDuration
        let width = timeline.table.width
        let height = timeline.table.height
        var resources = XMLNode("resources")
        resources.add(format(id: "r1", rate: rate, width: width, height: height))
        var assets: [String: (resource: String, format: String, start: Rational)] = [:]
        var next = 2
        for item in timeline.items where assets[item.clip.id] == nil {
            let clipWidth = item.clip.meta.width
            let clipHeight = item.clip.meta.height
            let formatID: String
            if item.sourceRate == rate && clipWidth == width && clipHeight == height {
                formatID = "r1"
            } else {
                formatID = "r\(next)"
                next += 1
                resources.add(format(id: formatID, rate: item.sourceRate, width: clipWidth, height: clipHeight))
            }
            let resourceID = "r\(next)"
            next += 1
            // F2: Die Datei beginnt bei ihrem Start-Timecode (0.2.0 schrieb immer 0s).
            let start = Rational(item.timecodeStart) / item.sourceRate
            assets[item.clip.id] = (resourceID, formatID, start)
            resources.add(
                XMLNode(
                    "asset",
                    [
                        ("id", resourceID), ("name", item.name), ("src", ExportText.fileURL(item.clip.media.path)),
                        ("start", ExportText.time(start)),
                        ("duration", ExportText.time(Rational(item.sourceFrames) / item.sourceRate)), ("hasVideo", "1"),
                        ("format", formatID),
                    ]))
        }
        let song = timeline.song
        let songDuration = Rational(song.sampleCount, Int64(song.sampleRate))
        let musicID = "r\(next)"
        resources.add(
            XMLNode(
                "asset",
                [
                    ("id", musicID), ("name", song.name), ("src", ExportText.fileURL(song.path)), ("start", "0s"),
                    ("duration", ExportText.time(songDuration)), ("hasAudio", "1"), ("audioSources", "1"),
                    ("audioChannels", "\(song.exportChannels)"), ("audioRate", "\(song.sampleRate)"),
                ]))

        var clips: [XMLNode] = []
        for (index, item) in timeline.items.enumerated() {
            let asset = assets[item.clip.id]!
            let sourceStart = asset.start + Rational(item.entry.sourceInFrame) / item.sourceRate
            let offset = Rational(item.entry.startFrame) * frame
            let duration = Rational(item.entry.durationFrames) * frame
            var node = XMLNode(
                "asset-clip",
                [
                    ("name", item.name), ("ref", asset.resource),
                    ("offset", ExportText.time(offset)),
                    ("start", ExportText.time(sourceStart)), ("duration", ExportText.time(duration)),
                    ("format", asset.format), ("tcFormat", "NDF"),
                ])
            // Als Primärhandlung liegt der Song unten; die Clips hängen verbunden darüber (Offset in Songzeit).
            if options.songPlacement == .primary { node.attributes.insert(("lane", "1"), at: 2) }
            if options.keywords, !item.clip.description.isEmpty {
                node.add(XMLNode("note", text: item.clip.description))
            }
            if options.songPlacement == .connected, index == 0 {
                node.add(
                    XMLNode(
                        "asset-clip",
                        [
                            ("name", song.name), ("ref", musicID), ("lane", "-1"),
                            ("offset", ExportText.time(sourceStart)), ("start", "0s"),
                            ("duration", ExportText.time(songDuration)), ("audioRole", "dialogue.music"),
                        ]))
            }
            if options.songPlacement == .connected {
                // Marker liegen in der Quellzeit des Clips, über dessen Bereich sie fallen.
                for marker in timeline.markers
                where marker.frame >= item.entry.startFrame && marker.frame < item.entry.endFrame {
                    node.add(
                        markerNode(
                            marker, start: sourceStart + Rational(marker.frame - item.entry.startFrame) * frame,
                            frame: frame))
                }
            }
            if options.keywords, !item.clip.tags.isEmpty {
                node.add(
                    XMLNode(
                        "keyword",
                        [
                            ("start", ExportText.time(sourceStart)), ("duration", ExportText.time(duration)),
                            ("value", item.clip.tags.joined(separator: ", ")),
                        ]))
            }
            clips.append(node)
        }

        var spine = XMLNode("spine")
        if options.songPlacement == .primary {
            var music = XMLNode(
                "asset-clip",
                [
                    ("name", song.name), ("ref", musicID), ("offset", "0s"), ("start", "0s"),
                    ("duration", ExportText.time(Rational(timeline.table.durationFrames) * frame)),
                    ("audioRole", "dialogue.music"),
                ])
            music.children = clips
            for marker in timeline.markers {
                music.add(markerNode(marker, start: Rational(marker.frame) * frame, frame: frame))
            }
            spine.add(music)
        } else {
            spine.children = clips
        }
        var sequence = XMLNode(
            "sequence",
            [
                ("format", "r1"), ("duration", ExportText.time(Rational(timeline.table.durationFrames) * frame)),
                ("tcStart", "0s"), ("tcFormat", "NDF"), ("audioLayout", "stereo"), ("audioRate", "48k"),
            ])
        sequence.add(spine)
        let project = XMLNode("project", [("name", timeline.name)], children: [sequence])
        let event = XMLNode("event", [("name", "SyllaBeat")], children: [project])
        let root = XMLNode(
            "fcpxml", [("version", "1.8")], children: [resources, XMLNode("library", children: [event])])
        return root.document(doctype: "fcpxml")
    }

    static func markerNode(_ marker: ExportMarker, start: Rational, frame: Rational) -> XMLNode {
        XMLNode(
            "marker",
            [("start", ExportText.time(start)), ("duration", ExportText.time(frame)), ("value", marker.name)]
                + (marker.kind == .section ? [] : [("note", marker.kind == .line ? "Textzeile" : "Takt")]))
    }
}
