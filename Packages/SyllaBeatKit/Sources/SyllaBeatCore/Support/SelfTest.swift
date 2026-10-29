import Foundation

/// Eingebaute Prüfungen ohne Medien (F-19): Zeitrechnung, Migration, Kompilieren, Schnitt-Engine, Exporte.
/// `sbtool selftest` und `SyllaBeat --self-test` nutzen dieselben Prüfungen.
public enum SelfTest {
    public struct Result: Sendable {
        public var passed: [String]
        public var failed: [String]

        public var ok: Bool { failed.isEmpty }
    }

    public static func run() -> Result {
        var result = Result(passed: [], failed: [])
        func check(_ name: String, _ body: () throws -> Bool) {
            do {
                if try body() { result.passed.append(name) } else { result.failed.append(name) }
            } catch {
                result.failed.append("\(name): \(error.localizedDescription)")
            }
        }
        check("Dezimalumwandlung") { Rational(seconds: 0.1) == Rational(1, 10) }
        check("Rundung ab halb aufwärts") { Rational(1, 2).roundedHalfUp() == 1 }
        check("NTSC-Frames") { FrameMath.frame(atSeconds: 1.0, rate: Rational(24000, 1001)) == 24 }
        let legacy = """
            {"version": 1, "name": "Selbsttest", "audio_path": "/tmp/song.wav", "timeline": {"fps_num": 25, "fps_den": 1, "width": 1920, "height": 1080},
             "clips": [{"id": "a", "path": "/tmp/a.mov", "name": "a.mov", "duration": 10, "fps_num": 50, "fps_den": 1,
                        "width": 1920, "height": 1080}],
             "audio": {"duration": 2.0, "beats": [0.5, 1.0, 1.5]},
             "plan": {"version": 1, "shots": [{"clip_id": "a", "start_beat": 0, "end_beat": 2, "source_in": 1.25},
                                              {"clip_id": "a", "start_beat": 2, "end_beat": 4, "source_in": 4}]}}
            """
        var project: Project?
        check("Migration erkannt") {
            let loaded = try ProjectFile.decode(Data(legacy.utf8))
            project = loaded.project
            return loaded.migratedFrom == 1 && loaded.project.analysis?.beats.count == 3
        }
        if let project {
            check("Schnittgrenzen und Quellframes 50p") {
                let table = try CutCompiler.compile(project, cut: project.cut!)
                return table.entries.map(\.startFrame) == [0, 25] && table.entries[0].sourceInFrame == 63
                    && table.entries[0].sourceOutFrame == 113
            }
            check("v2 verlustfrei gesichert") {
                let roundTrip = try ProjectFile.decode(ProjectFile.encode(project))
                return roundTrip.project == project && roundTrip.migratedFrom == nil
            }
            check("Exporte (FCPXML, xmeml, EDL, OTIO)") {
                let timeline = try ExportTimeline(project)
                let fcpxml = FCPXMLExporter.document(timeline)
                let xmeml = try XMEMLExporter.document(timeline)
                let edl = EDLExporter.document(timeline)
                let otio = try OTIOExporter.document(timeline)
                return fcpxml.contains("<spine>") && xmeml.contains("<xmeml") && edl.contains("001  AX")
                    && otio.contains("Timeline.1")
            }
        }
        check("Schnitt-Engine und Invarianten") {
            for seed in UInt64(0)..<20 {
                let synthetic = SyntheticProject.make(seed: seed)
                guard let cut = CutEngine.generate(synthetic, style: synthetic.style),
                    CutValidator.validate(synthetic, cut: cut).isEmpty
                else { return false }
            }
            return true
        }
        return result
    }
}
