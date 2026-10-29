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

      probe <Datei> …            technische Daten von Videos
      truth <Ordner>             Metadaten und Schnitte gegen clips.truth.json prüfen
      import <Ordner> [<aus>] [--parallel N]   Ordner analysieren (Zeitmessung), optional als Projekt sichern
      model-install [<ID>] [<Ordner>]   Modell laden und prüfen (Standard SigLIP 2; qwen3-vl-4b-8bit, qwen3-vl-4b-4bit);
                                 mit Ordner aus lokalen Dateien statt aus dem Netz
      embed <Projekt>            fehlende Szenen-Embeddings berechnen
      search <Projekt> <Text>    semantische Suche, beste 5 Clips

      song <Audiodatei>          Beats, Tempo, Takte und Abschnitte eines Songs
      songtruth <Ordner>         Songanalyse gegen *.truth.json bewerten
      bench-timeline             Zeichenzeit der Timeline (6 min, 720 Beats) messen
      bench-cut                  Schnitt-Engine mit 500 Clips und 6-min-Song messen (E10)
      validate <Projekt>         Schnitt prüfen: Invarianten, Anker, Refrain-Kopien
      export <Projekt> <Ordner> [--ziel finalCut|resolve|premiere|archive] [--wie-020] [--song-primaer] [--takte]
                                 [--ohne-pruefung]   Timeline und Archiv exportieren
      autocut <Projekt> <Song> [<Songtext>]   Song analysieren (optional Text ausrichten) und schneiden
      preview <Projekt>          Vorschau-Komposition aufbauen und prüfen
      storyboard <Projekt> [--laeufe N] [--anbieter apple|ollama=…|anthropic] [--regie "…"] [--sichern]
                                 KI-Regie Stufe 1 ausführen und messen
      beschreiben <Projekt> [<Anbieter>] [<Anzahl>]   Bildbeschreibungen für Clips ohne Beschreibung
      vergleich <Projekt> <Regieanweisung> <Ordner>   Blindvergleich ohne/mit Storyboard (Kontaktbogen)
      bench-preview <Ordner>     Vorschau-Neuaufbau mit 500 Dateien messen (Ordner: tests/Fixtures/media)
      wordtruth <Ordner>         Transkription, Wortzeit-Korrektur und Ausrichtung gegen *.truth.json bewerten
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
    let result = SelfTest.run()
    for name in result.failed { print("✗ \(name)") }
    guard result.ok else {
        throw ToolError(description: "Selbsttest fehlgeschlagen (\(result.failed.count) Prüfungen)")
    }
    print("Selbsttest bestanden (\(result.passed.count) Prüfungen).")
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch (arguments.first, arguments.count) {
    case ("info", 2): try info(arguments[1])
    case ("migrate", 3): try migrate(arguments[1], arguments[2])
    case ("compile", 2): try compile(arguments[1])
    case ("selftest", 1): try selftest()
    case ("version", 1): print("sbtool \(BuildInfo.version)")
    case ("probe", 2...): try await probe(Array(arguments.dropFirst()))
    case ("truth", 2): try await checkTruth(arguments[1])
    case ("import", 2...):
        var rest = Array(arguments.dropFirst(2))
        var parallel = 4
        if let flag = rest.firstIndex(of: "--parallel"), flag + 1 < rest.count, let value = Int(rest[flag + 1]) {
            parallel = value
            rest.removeSubrange(flag...(flag + 1))
        }
        try await importFolder(arguments[1], output: rest.first, parallel: parallel)
    case ("model-install", 1...3): try await installModel(Array(arguments.dropFirst()))
    case ("embed", 2): try await embedProject(arguments[1])
    case ("song", 2): try await analyzeSong(arguments[1])
    case ("songtruth", 2): try await evaluateSongs(arguments[1])
    case ("wordtruth", 2): try await evaluateTranscription(arguments[1])
    case ("bench-timeline", 1): await MainActor.run { benchTimeline() }
    case ("bench-cut", 1): try benchCut()
    case ("validate", 2): try validateCut(arguments[1])
    case ("export", 3...): try exportCommand(Array(arguments.dropFirst()))
    case ("autocut", 3): try await autocut(arguments[1], song: arguments[2])
    case ("autocut", 4): try await autocut(arguments[1], song: arguments[2], lyrics: arguments[3])
    case ("preview", 2): try await previewProject(arguments[1])
    case ("beschreiben", 2...4):
        try await describeCommand(
            arguments[1], spec: arguments.count > 2 ? arguments[2] : "apple",
            limit: arguments.count > 3 ? Int(arguments[3]) ?? 5 : 1000)
    case ("storyboard", 2...): try await storyboardCommand(Array(arguments.dropFirst()))
    case ("vergleich", 4):
        try await compareStoryboard(arguments[1], brief: arguments[2], output: arguments[3])
    case ("bench-preview", 2): try await benchPreview(fixtures: URL(fileURLWithPath: arguments[1]))
    case ("search", 3...): try await search(arguments[1], query: arguments.dropFirst(2).joined(separator: " "))
    default:
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(2)
    }
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    FileHandle.standardError.write(Data("Fehler: \(message)\n".utf8))
    exit(1)
}
