// sbtool: Kommandozeile für Selbsttest, End-to-End-Tests und Benchmarks. Nutzt dieselben Pakete wie die App.
import Foundation
import SyllaBeatCore

let usage = """
    Aufruf: sbtool <Befehl> [Argumente]

      info <Projekt>             Clips, Beats, Abschnitte und Schnitt eines Projekts anzeigen (v1 oder v2)
      migrate <ein> <aus>        0.2.0-Projekt (v1) nach v2 umwandeln
      compile <Projekt>          Frame-Tabelle des aktiven Schnitts als JSON ausgeben
      selftest                   eingebaute Prüfungen ohne Medien ausführen
      version                    Version ausgeben
    """

struct ToolError: Error, CustomStringConvertible {
    var description: String
}

func load(_ path: String) throws -> ProjectFile.Loaded {
    try ProjectFile.decode(Data(contentsOf: URL(fileURLWithPath: path)))
}

func info(_ path: String) throws {
    let loaded = try load(path)
    let project = loaded.project
    print("Projekt: \(project.name)")
    if let version = loaded.migratedFrom { print("Format: v\(version) (beim Lesen nach v2 migriert)") }
    print("Timeline: \(project.timeline.fps) fps, \(project.timeline.width)×\(project.timeline.height)")
    print("Clips: \(project.clips.count)")
    for clip in project.clips {
        print(
            "  \(clip.name)  \(clip.meta.fps) fps  \(String(format: "%.2f", clip.meta.duration)) s  \(clip.scenes.count) Szenen"
        )
    }
    if let analysis = project.analysis {
        print(
            "Song: \(String(format: "%.2f", analysis.duration)) s, \(analysis.beats.count) Beats, \(Int(analysis.tempo.rounded())) BPM"
        )
        print("Abschnitte: " + analysis.sections.map(\.label).joined(separator: " · "))
    }
    if let cut = project.cut {
        print("Schnitt: \(cut.shots.count) Einstellungen (\(cut.name))")
    }
    for note in project.legacy?.notes ?? [] { print("Hinweis: \(note)") }
}

func migrate(_ input: String, _ output: String) throws {
    let loaded = try load(input)
    guard loaded.migratedFrom != nil else { throw ToolError(description: "\(input) ist bereits im Format v2.") }
    try ProjectFile.encode(loaded.project).write(to: URL(fileURLWithPath: output), options: .atomic)
    print("Gesichert als v2: \(output)")
}

func compile(_ path: String) throws {
    let project = try load(path).project
    guard let cut = project.cut else { throw ToolError(description: "Das Projekt enthält keinen Schnitt.") }
    let table = try CutCompiler.compile(project, cut: cut)
    let rows = table.entries.map { entry -> [String: Any] in
        [
            "clip_id": entry.clipID, "start": entry.startFrame, "end": entry.endFrame,
            "source_in_frame": entry.sourceInFrame, "source_out_frame": entry.sourceOutFrame,
            "source_fps": entry.sourceFPS.description,
        ]
    }
    let object: [String: Any] = [
        "fps": table.fps.description, "duration_frames": table.durationFrames, "shots": rows,
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func selftest() throws {
    var checks = 0
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ToolError(description: "Selbsttest fehlgeschlagen: \(message)") }
        checks += 1
    }
    try check(Rational(seconds: 0.1) == Rational(1, 10), "Dezimalumwandlung")
    try check((Rational(1, 2)).roundedHalfUp() == 1, "Rundung ab halb aufwärts")
    try check(FrameMath.frame(atSeconds: 1.0, rate: Rational(24000, 1001)) == 24, "NTSC-Frames")
    let legacy = """
        {"version": 1, "name": "Selbsttest", "timeline": {"fps_num": 25, "fps_den": 1, "width": 1920, "height": 1080},
         "clips": [{"id": "a", "path": "/tmp/a.mov", "name": "a.mov", "duration": 10, "fps_num": 50, "fps_den": 1,
                    "width": 1920, "height": 1080}],
         "audio": {"duration": 2.0, "beats": [0.5, 1.0, 1.5]},
         "plan": {"version": 1, "shots": [{"clip_id": "a", "start_beat": 0, "end_beat": 2, "source_in": 1.25},
                                          {"clip_id": "a", "start_beat": 2, "end_beat": 4, "source_in": 4}]}}
        """
    let loaded = try ProjectFile.decode(Data(legacy.utf8))
    try check(loaded.migratedFrom == 1, "Migration erkannt")
    let project = loaded.project
    try check(project.analysis?.beats.count == 3, "Beats übernommen")
    let table = try CutCompiler.compile(project, cut: project.cut!)
    try check(table.entries.map(\.startFrame) == [0, 25], "Schnittgrenzen")
    try check(table.entries[0].sourceInFrame == 63 && table.entries[0].sourceOutFrame == 113, "Quellframes 50p")
    let roundTrip = try ProjectFile.decode(ProjectFile.encode(project))
    try check(roundTrip.project == project && roundTrip.migratedFrom == nil, "v2 verlustfrei gesichert")
    print("Selbsttest bestanden (\(checks) Prüfungen).")
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch (arguments.first, arguments.count) {
    case ("info", 2): try info(arguments[1])
    case ("migrate", 3): try migrate(arguments[1], arguments[2])
    case ("compile", 2): try compile(arguments[1])
    case ("selftest", 1): try selftest()
    case ("version", 1): print("sbtool \(BuildInfo.version)")
    default:
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(2)
    }
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    FileHandle.standardError.write(Data("Fehler: \(message)\n".utf8))
    exit(1)
}
