import Foundation

/// FCP-7-XML (xmeml v4) für DaVinci Resolve und Premiere: eine Videospur und der Song als verknüpfte Stereo-Kanäle
/// (wie 0.2.0). Neu: Start-Timecode der Dateien (F2), Sequenzmarker, Beschreibung und Schlagwörter als Kommentare.
public enum XMEMLExporter {
    /// xmeml kennt nur ganze Raten und 1000/1001-Raten.
    static func rate(_ rate: Rational) throws -> XMLNode {
        let base: Int64
        let ntsc: Bool
        if rate.denominator == 1 {
            (base, ntsc) = (rate.numerator, false)
        } else if (rate * Rational(1001, 1000)).denominator == 1 {
            (base, ntsc) = ((rate * Rational(1001, 1000)).numerator, true)
        } else {
            throw ExportError.unsupportedRate(rate, format: "FCP-7-XML")
        }
        return XMLNode("rate", children: [.value("timebase", base), .value("ntsc", ntsc ? "TRUE" : "FALSE")])
    }

    static func timecode(_ rate: Rational, startFrames: Int64 = 0) throws -> XMLNode {
        XMLNode(
            "timecode",
            children: [
                try self.rate(rate), .value("string", ExportText.timecode(startFrames, rate: rate)),
                .value("frame", startFrames), .value("displayformat", "NDF"),
            ])
    }

    static func sampleVideo(_ rate: Rational, width: Int, height: Int) throws -> XMLNode {
        XMLNode(
            "samplecharacteristics",
            children: [
                try self.rate(rate), .value("width", width), .value("height", height), .value("anamorphic", "FALSE"),
                .value("pixelaspectratio", "square"), .value("fielddominance", "none"),
            ])
    }

    public static func document(_ timeline: ExportTimeline, options: ExportOptions = ExportOptions()) throws -> String {
        let rate = timeline.rate
        let frames = timeline.table.durationFrames
        var sequence = XMLNode("sequence", [("id", "sequence-1")])
        sequence.add(.value("name", timeline.name))
        sequence.add(.value("duration", frames))
        sequence.add(try self.rate(rate))
        sequence.add(try timecode(rate))
        sequence.add(.value("in", 0))
        sequence.add(.value("out", frames))

        var track = XMLNode("track")
        var fileIDs: [String: String] = [:]
        for item in timeline.items {
            let sourceRate = item.sourceRate
            var clipitem = XMLNode("clipitem", [("id", item.id)])
            clipitem.add(.value("name", item.name))
            clipitem.add(.value("enabled", "TRUE"))
            clipitem.add(.value("duration", item.sourceFrames))
            clipitem.add(try self.rate(sourceRate))
            clipitem.add(.value("start", item.entry.startFrame))
            clipitem.add(.value("end", item.entry.endFrame))
            clipitem.add(.value("in", item.entry.sourceInFrame))
            clipitem.add(.value("out", item.entry.sourceOutFrame))
            clipitem.add(.value("anamorphic", "FALSE"))
            clipitem.add(.value("pixelaspectratio", "square"))
            clipitem.add(.value("fielddominance", "none"))
            let defined = fileIDs[item.clip.id] != nil
            let fileID = fileIDs[item.clip.id] ?? "video-file-\(fileIDs.count + 1)"
            fileIDs[item.clip.id] = fileID
            var file = XMLNode("file", [("id", fileID)])
            if !defined {
                file.add(.value("name", item.name))
                file.add(.value("pathurl", ExportText.fileURL(item.clip.media.path)))
                file.add(try self.rate(sourceRate))
                file.add(.value("duration", item.sourceFrames))
                file.add(try timecode(sourceRate, startFrames: item.timecodeStart))
                var video = XMLNode("video", children: [.value("duration", item.sourceFrames)])
                video.add(try sampleVideo(sourceRate, width: item.clip.meta.width, height: item.clip.meta.height))
                file.add(XMLNode("media", children: [video]))
            }
            clipitem.add(file)
            clipitem.add(XMLNode("sourcetrack", children: [.value("mediatype", "video"), .value("trackindex", 1)]))
            if options.keywords, !(item.clip.description.isEmpty && item.clip.tags.isEmpty) {
                var comments = XMLNode("comments")
                if !item.clip.description.isEmpty { comments.add(.value("mastercomment1", item.clip.description)) }
                if !item.clip.tags.isEmpty {
                    comments.add(.value("mastercomment2", item.clip.tags.joined(separator: ", ")))
                }
                clipitem.add(comments)
            }
            track.add(clipitem)
        }
        track.add(.value("enabled", "TRUE"))
        track.add(.value("locked", "FALSE"))

        var video = XMLNode("video")
        video.add(
            XMLNode(
                "format", children: [try sampleVideo(rate, width: timeline.table.width, height: timeline.table.height)])
        )
        video.add(track)

        let song = timeline.song
        let channels = song.exportChannels
        var audio = XMLNode("audio")
        audio.add(.value("channelcount", 2))
        audio.add(
            XMLNode(
                "format",
                children: [
                    XMLNode(
                        "samplecharacteristics", children: [.value("depth", 16), .value("samplerate", song.sampleRate)])
                ]))
        var group = XMLNode(
            "group", children: [.value("index", 1), .value("numchannels", 2), .value("downmix", 0)])
        for channel in 1...2 { group.add(XMLNode("channel", children: [.value("index", channel)])) }
        audio.add(XMLNode("outputs", children: [group]))
        for channel in 1...channels {
            var item = XMLNode("clipitem", [("id", "music-channel-\(channel)")])
            item.add(.value("name", song.name))
            item.add(.value("enabled", "TRUE"))
            item.add(.value("duration", frames))
            item.add(try self.rate(rate))
            for (key, value) in [("start", 0), ("end", frames), ("in", 0), ("out", frames)] {
                item.add(.value(key, value))
            }
            var file = XMLNode("file", [("id", "music-file")])
            if channel == 1 {
                file.add(.value("name", song.name))
                file.add(.value("pathurl", ExportText.fileURL(song.path)))
                file.add(try self.rate(rate))
                file.add(.value("duration", FrameMath.ceilFrames(seconds: song.duration, rate: rate)))
                file.add(try timecode(rate))
                let sample = XMLNode(
                    "samplecharacteristics", children: [.value("depth", 16), .value("samplerate", song.sampleRate)])
                file.add(
                    XMLNode(
                        "media", children: [XMLNode("audio", children: [sample, .value("channelcount", channels)])]))
            }
            item.add(file)
            item.add(XMLNode("sourcetrack", children: [.value("mediatype", "audio"), .value("trackindex", channel)]))
            for linked in 1...channels {
                item.add(
                    XMLNode(
                        "link",
                        children: [
                            .value("linkclipref", "music-channel-\(linked)"), .value("mediatype", "audio"),
                            .value("trackindex", linked), .value("clipindex", 1), .value("groupindex", 1),
                        ]))
            }
            audio.add(
                XMLNode(
                    "track",
                    children: [
                        item, .value("enabled", "TRUE"), .value("locked", "FALSE"),
                        .value("outputchannelindex", channel),
                    ]))
        }
        sequence.add(XMLNode("media", children: [video, audio]))
        for marker in timeline.markers {
            sequence.add(
                XMLNode(
                    "marker",
                    children: [
                        .value(
                            "comment",
                            marker.kind == .section ? "Abschnitt" : marker.kind == .line ? "Textzeile" : "Takt"),
                        .value("name", marker.name), .value("in", marker.frame), .value("out", -1),
                    ]))
        }
        return XMLNode("xmeml", [("version", "4")], children: [sequence]).document(doctype: "xmeml")
    }
}
