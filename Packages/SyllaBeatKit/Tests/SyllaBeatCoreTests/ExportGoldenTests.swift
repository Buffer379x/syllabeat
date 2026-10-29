import Foundation
import Testing

@testable import SyllaBeatCore

/// Exporte gegen die Golden-Dateien aus 0.2.0 (semantisch: XML-Baum, Zahlen rational, JSON mit Toleranz).
/// Bewusste Abweichungen stehen in `tests/Fixtures/golden-v0.2.0/ABWEICHUNGEN.md` (F1, F2).
@Suite struct ExportGoldenTests {
    static func project(_ name: String) throws -> Project {
        try ProjectFile.decode(Fixtures.data(Fixtures.golden.appendingPathComponent("\(name)/project.v1.json"))).project
    }

    static func golden(_ name: String, _ file: String) throws -> String {
        try String(contentsOf: Fixtures.golden.appendingPathComponent("\(name)/\(file)"), encoding: .utf8)
    }

    /// Unterschiede zweier XML-Bäume (Namen, Attribute ohne Reihenfolge, Text, Kinder in Reihenfolge).
    static func differences(_ a: XMLElement, _ b: XMLElement, path: String = "") -> [String] {
        let here = path + "/" + (a.name ?? "?")
        guard a.name == b.name else { return ["\(here): Element \(a.name ?? "") ≠ \(b.name ?? "")"] }
        var result: [String] = []
        let attributesA = Dictionary(uniqueKeysWithValues: (a.attributes ?? []).map { ($0.name!, $0.stringValue!) })
        let attributesB = Dictionary(uniqueKeysWithValues: (b.attributes ?? []).map { ($0.name!, $0.stringValue!) })
        if attributesA != attributesB { result.append("\(here): Attribute \(attributesA) ≠ \(attributesB)") }
        let childrenA = (a.children ?? []).compactMap { $0 as? XMLElement }
        let childrenB = (b.children ?? []).compactMap { $0 as? XMLElement }
        if childrenA.isEmpty, childrenB.isEmpty {
            let textA = a.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let textB = b.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if textA != textB { result.append("\(here): Text „\(textA)“ ≠ „\(textB)“") }
        }
        if childrenA.count != childrenB.count {
            result.append("\(here): \(childrenA.count) ≠ \(childrenB.count) Kinder")
        }
        for (x, y) in zip(childrenA, childrenB) { result += differences(x, y, path: here) }
        return result
    }

    static func xmlDifferences(_ produced: String, _ expected: String) throws -> [String] {
        let a = try XMLDocument(xmlString: produced, options: [])
        let b = try XMLDocument(xmlString: expected, options: [])
        return differences(a.rootElement()!, b.rootElement()!)
    }

    /// JSON-Vergleich mit Toleranz für Gleitkommazahlen.
    static func jsonDifferences(_ a: Any, _ b: Any, path: String = "") -> [String] {
        switch (a, b) {
        case (let x as [String: Any], let y as [String: Any]):
            guard Set(x.keys) == Set(y.keys) else {
                return ["\(path): Schlüssel \(x.keys.sorted()) ≠ \(y.keys.sorted())"]
            }
            return x.keys.sorted().flatMap { jsonDifferences(x[$0]!, y[$0]!, path: path + "." + $0) }
        case (let x as [Any], let y as [Any]):
            guard x.count == y.count else { return ["\(path): \(x.count) ≠ \(y.count) Einträge"] }
            return zip(x, y).enumerated().flatMap { jsonDifferences($1.0, $1.1, path: path + "[\($0)]") }
        case (let x as NSNumber, let y as NSNumber):
            return abs(x.doubleValue - y.doubleValue) <= 1e-9 * max(1, abs(y.doubleValue))
                ? [] : ["\(path): \(x) ≠ \(y)"]
        case (is NSNull, is NSNull):
            return []
        case (let x as String, let y as String):
            return x == y ? [] : ["\(path): „\(x)“ ≠ „\(y)“"]
        default:
            return ["\(path): \(a) ≠ \(b)"]
        }
    }

    @Test(arguments: Fixtures.goldenNames)
    func fcpxmlMatchesVersion020(name: String) throws {
        let produced = try ProjectExporter.content(.fcpxml, project: Self.project(name), options: .legacy)
        let differences = try Self.xmlDifferences(produced, Self.golden(name, "timeline.fcpxml"))
        #expect(differences.isEmpty, "\(name): \(differences.prefix(5))")
    }

    @Test(arguments: Fixtures.goldenNames)
    func xmemlMatchesVersion020(name: String) throws {
        let produced = try ProjectExporter.content(.xmeml, project: Self.project(name), options: .legacy)
        let differences = try Self.xmlDifferences(produced, Self.golden(name, "timeline.xml"))
        #expect(differences.isEmpty, "\(name): \(differences.prefix(5))")
    }

    @Test(arguments: Fixtures.goldenNames)
    func otioMatchesVersion020(name: String) throws {
        let produced = try ProjectExporter.content(.otio, project: Self.project(name), options: .legacy)
        let a = try JSONSerialization.jsonObject(with: Data(produced.utf8))
        let b = try JSONSerialization.jsonObject(with: Data(Self.golden(name, "timeline.otio").utf8))
        let differences = Self.jsonDifferences(a, b)
        #expect(differences.isEmpty, "\(name): \(differences.prefix(5))")
    }

    /// EDL: alles gleich bis auf die Quell-Timecodes von Clips mit anderer Rate als die Timeline (F1).
    @Test(arguments: Fixtures.goldenNames)
    func edlMatchesVersion020ExceptF1(name: String) throws {
        let project = try Self.project(name)
        let timeline = try ExportTimeline(project, options: .legacy)
        let produced = EDLExporter.document(timeline).components(separatedBy: "\n")
        let expected = try Self.golden(name, "timeline.edl").components(separatedBy: "\n")
        #expect(produced.count == expected.count)
        var event = 0
        for (line, reference) in zip(produced, expected) {
            guard line.first?.isNumber == true else {
                #expect(line == reference, "\(name)")
                continue
            }
            let item = timeline.items[event]
            event += 1
            let fields = line.split(separator: " "), golden = reference.split(separator: " ")
            #expect(fields.count == 8 && golden.count == 8, "\(name): \(line)")
            // Record-Timecodes, Spur und Übergang immer gleich.
            #expect(
                Array(fields[0...3]) == Array(golden[0...3]) && Array(fields[6...7]) == Array(golden[6...7]),
                "\(name): \(line)")
            if item.sourceRate == timeline.rate {
                #expect(Array(fields[4...5]) == Array(golden[4...5]), "\(name): \(line)")
            }
        }
    }

    /// F1: 50p-Clip in 25p-Timeline hat in der EDL dieselbe Länge wie in der Timeline (0.2.0: halbe Länge, `:38`).
    @Test func edlFixesF1() throws {
        let timeline = try ExportTimeline(Self.project("g1-basis-25p"), options: .legacy)
        let lines = EDLExporter.document(timeline).components(separatedBy: "\n").filter { $0.first?.isNumber == true }
        #expect(lines[2].contains("00:00:00:00 00:00:01:00 01:00:02:18 01:00:03:18"), "\(lines[2])")
        // Ereignis 005: Quell-In 63 Frames bei 50p = 1,26 s = 31,5 Frames bei 25p → aufgerundet 32.
        #expect(lines[4].contains("00:00:01:07 00:00:02:07 01:00:04:18 01:00:05:18"), "\(lines[4])")
        for line in lines {
            let fields = line.split(separator: " ")
            for timecode in fields[4...7] { #expect(Int(timecode.suffix(2))! < 25, "ungültiger Frame in \(line)") }
        }
    }

    /// F2: Start-Timecode der Datei verschiebt die Quell-Timecodes (EDL, xmeml, FCPXML).
    @Test func timecodeStartIsUsed() throws {
        var project = try Self.project("g1-basis-25p")
        let index = project.clips.firstIndex { $0.id == "clip-a" }!
        project.clips[index].meta.startTimecode = "10:00:00:00"
        let timeline = try ExportTimeline(project, options: .legacy)
        let edl = EDLExporter.document(timeline).components(separatedBy: "\n").filter { $0.first?.isNumber == true }
        #expect(edl[0].contains("10:00:04:00 10:00:05:18"), "\(edl[0])")
        let xmeml = try XMEMLExporter.document(timeline, options: .legacy)
        #expect(xmeml.contains("<string>10:00:00:00</string>"))
        #expect(xmeml.contains("<frame>900000</frame>"))
        let fcpxml = FCPXMLExporter.document(timeline, options: .legacy)
        #expect(fcpxml.contains("start=\"36000s\" duration=\"10s\""))
        #expect(fcpxml.contains("offset=\"0s\" start=\"36004s\""))
    }

    /// I7: Alle Formate übernehmen Dauern und Frames exakt aus der Frame-Tabelle.
    @Test(arguments: Fixtures.goldenNames)
    func durationsMatchFrameTable(name: String) throws {
        let project = try Self.project(name)
        let timeline = try ExportTimeline(project)
        let table = timeline.table
        // xmeml: start/end je Clipitem = Tabelle.
        let xmeml = try XMLDocument(xmlString: try XMEMLExporter.document(timeline), options: [])
        let items = try xmeml.nodes(forXPath: "//video/track/clipitem").compactMap { $0 as? XMLElement }
        #expect(items.count == table.entries.count)
        for (item, entry) in zip(items, table.entries) {
            #expect(item.elements(forName: "start").first?.stringValue == "\(entry.startFrame)")
            #expect(item.elements(forName: "end").first?.stringValue == "\(entry.endFrame)")
        }
        // FCPXML: Summe der Clipdauern = Sequenzdauer, Offsets lückenlos.
        let fcpxml = try XMLDocument(xmlString: FCPXMLExporter.document(timeline), options: [])
        let clips = try fcpxml.nodes(forXPath: "//spine/asset-clip").compactMap { $0 as? XMLElement }
        var position = Rational.zero
        for (clip, entry) in zip(clips, table.entries) {
            #expect(clip.attribute(forName: "offset")?.stringValue == ExportText.time(position))
            let duration = Rational(entry.durationFrames) / table.fps
            #expect(clip.attribute(forName: "duration")?.stringValue == ExportText.time(duration))
            position = position + duration
        }
        #expect(position == Rational(table.durationFrames) / table.fps)
        // OTIO: Summe der Videodauern in Timeline-Frames.
        let otio = OTIOExporter.object(timeline)
        let tracks = ((otio["tracks"] as! [String: Any])["children"] as! [[String: Any]])
        let video = tracks[1]["children"] as! [[String: Any]]
        let total = video.reduce(0.0) { sum, clip in
            sum + ((((clip["source_range"] as! [String: Any])["duration"]) as! [String: Any])["value"] as! Double)
        }
        #expect(Int64(total) == table.durationFrames)
    }
}

/// FCPXML gegen die DTD aus dem installierten Final Cut Pro (nur lokal; die DTD wird nicht weitergegeben).
@Suite struct FCPXMLValidationTests {
    static let dtd = URL(
        fileURLWithPath:
            "/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_8.dtd"
    )

    static func validate(_ document: String) throws -> (ok: Bool, output: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dtd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // xmllint scheitert an Leerzeichen im DTD-Pfad: Kopie in einen Ordner ohne Leerzeichen.
        let dtd = folder.appendingPathComponent("fcpxml18.dtd")
        try FileManager.default.copyItem(at: Self.dtd, to: dtd)
        let file = folder.appendingPathComponent("timeline.fcpxml")
        try document.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
        process.arguments = ["--noout", "--dtdvalid", dtd.path, file.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus == 0, output)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: dtd.path)), arguments: Fixtures.goldenNames)
    func allVariantsAreValid(name: String) throws {
        var project = try ExportGoldenTests.project(name)
        // Marker aus Abschnitten, Zeilen und Takten; Schlagwörter und Beschreibung.
        if var analysis = project.analysis {
            analysis.sections = [
                SongSection(id: "a", kind: .verse, label: "Strophe „1“ & mehr", start: 0, end: analysis.duration / 2),
                SongSection(
                    id: "b", kind: .chorus, label: "Refrain", start: analysis.duration / 2, end: analysis.duration),
            ]
            analysis.lines = [LyricLine(id: "l1", text: "Und das <Meer> singt", start: 1, end: 2)]
            project.analysis = analysis
        }
        for index in project.clips.indices {
            project.clips[index].tags = ["Strand", "Meer"]
            project.clips[index].description = "Wellen am Strand"
        }
        for placement in ExportOptions.SongPlacement.allCases {
            let options = ExportOptions(barMarkers: true, songPlacement: placement)
            let document = try ProjectExporter.content(.fcpxml, project: project, options: options)
            let result = try Self.validate(document)
            #expect(result.ok, "\(name) \(placement): \(result.output.prefix(400))")
        }
        let legacy = try Self.validate(try ProjectExporter.content(.fcpxml, project: project, options: .legacy))
        #expect(legacy.ok, "\(name) legacy: \(legacy.output.prefix(400))")
    }
}
