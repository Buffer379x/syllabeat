import Foundation
import SyllaBeatAudio
import SyllaBeatCore
import SyllaBeatMedia
import SyllaBeatModels
import SyllaBeatUI

/// E10: 500 Clips, 6-min-Song. Misst Erzeugen, Neu würfeln mit fixierten Shots und Teilneuberechnung je Preset.
func benchCut() throws {
    var project = SyntheticProject.make(seed: 42, clips: 500...500, duration: 360...360)
    guard var analysis = project.analysis else { throw ToolError(description: "Synthetisches Projekt ohne Analyse") }
    // Textzeilen alle 4 s mit Ähnlichkeiten zu allen Szenen, wie nach der Bildsuche.
    analysis.lines = stride(from: 0.0, to: analysis.duration - 4, by: 4).enumerated().map { index, start in
        LyricLine(id: "l\(index)", text: "Zeile \(index)", start: start, end: start + 3.5)
    }
    project.analysis = analysis
    var random = SeededRandom(seed: 7)
    var values: [String: [String: Float]] = [:]
    for line in analysis.lines {
        var row: [String: Float] = [:]
        for clip in project.clips { for scene in clip.scenes { row[scene.id] = Float(random.unit()) * 0.1 } }
        values[line.id] = row
    }
    let text = TextScores(values)
    let scenes = project.clips.reduce(0) { $0 + $1.scenes.count }
    print("Projekt: \(project.clips.count) Clips, \(scenes) Szenen, \(analysis.beats.count) Beats, 6:00 min")

    func measure(_ label: String, runs: Int = 7, _ body: () throws -> Void) rethrows {
        var times: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        times.sort()
        let padded = label.padding(toLength: 38, withPad: " ", startingAt: 0)
        print("  \(padded)" + String(format: "Median %6.1f ms   Max %6.1f ms", times[runs / 2], times[runs - 1]))
    }

    for preset in CutStyle.Preset.allCases {
        var styled = project
        styled.style = CutStyle(preset: preset, seed: 1)
        try GenerateCut(textScores: text).apply(to: &styled)
        let shots = styled.cut?.shots.count ?? 0
        print("\(preset.title): \(shots) Einstellungen")
        try measure("Schnitt erzeugen") {
            var copy = styled
            try GenerateCut(textScores: text).apply(to: &copy)
        }
        var locked = styled
        for index in stride(from: 0, to: shots, by: 10) {
            try SetShotLocked(shotID: "shot-\(index + 1)", locked: true).apply(to: &locked)
        }
        try measure("Neu würfeln (jede 10. fixiert)") {
            var copy = locked
            try Reroll(textScores: text).apply(to: &copy)
        }
        let selection = Set((shots / 3..<shots / 3 + 8).map { "shot-\($0 + 1)" })
        try measure("Teil neu schneiden (8 Einstellungen)") {
            var copy = styled
            try RecutShots(shotIDs: selection, textScores: text).apply(to: &copy)
        }
        try measure("Drei Varianten", runs: 3) {
            var copy = styled
            try CreateVariants(textScores: text).apply(to: &copy)
        }
    }
}

/// Vorschau-Neuaufbau (Ziel < 300 ms): 500 verschiedene Dateien (Verweise auf die Testclips), 6-min-Song, „Hektisch“.
@MainActor
func benchPreview(fixtures: URL) async throws {
    let names = ["schnitte-25.mov", "schnitte-23976.mov", "schnitte-50.mov", "schnitte-5994.mov"]
    var metas: [ClipMetadata] = []
    for name in names { metas.append(try await MediaProbe.read(fixtures.appendingPathComponent(name))) }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sbtool-preview-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var project = SyntheticProject.make(seed: 42, clips: 1...1, duration: 360...360)
    var random = SeededRandom(seed: 3)
    project.clips = try (0..<500).map { index in
        let link = folder.appendingPathComponent("clip-\(index).mov")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: fixtures.appendingPathComponent(names[index % names.count]))
        let meta = metas[index % names.count]
        let scene = ClipScene(
            id: "c\(index)-s0", start: 0, end: meta.duration,
            features: SceneFeatures(
                aesthetics: random.unit() * 2 - 1, isUtility: false, faceCount: 0, shotSize: .medium, sharpness: 200,
                motion: random.unit()))
        return Clip(id: "c\(index)", media: MediaRef(path: link.path), meta: meta, scenes: [scene])
    }
    project.style = CutStyle(preset: .hectic, seed: 1)
    try GenerateCut().apply(to: &project)
    guard let cut = project.cut else { throw ToolError(description: "Kein Schnitt") }
    let paths = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.id, $0.media.path) })
    let builder = PreviewBuilder()
    let table = try CutCompiler.compile(project, cut: cut)
    let cold = try await builder.build(table: table, paths: paths, song: nil, fit: .fill)
    print("Vorschau: \(table.entries.count) Einstellungen aus \(Set(table.entries.map(\.clipID)).count) Dateien")
    print(String(format: "  erster Aufbau (Dateien laden)        %6.1f ms", cold.milliseconds))
    var times: [Double] = []
    for _ in 0..<7 {
        try Reroll().apply(to: &project)
        let table = try CutCompiler.compile(project, cut: project.cut!)
        times.append(try await builder.build(table: table, paths: paths, song: nil, fit: .fill).milliseconds)
    }
    times.sort()
    print(String(format: "  Neuaufbau nach „Neu würfeln“         Median %6.1f ms   Max %6.1f ms", times[3], times[6]))

    // E2: Rasterkorrekturen mit Schnitt-Reparatur, Kompilieren und neuer Vorschau (Ziel < 1 s je Schritt).
    let steps: [(String, any EditCommand)] = [
        ("Tempo ÷2", ScaleTempo(factor: .half)), ("Taktanfang setzen", SetDownbeat(beatIndex: 2)),
        ("+30 ms", ShiftBeats(milliseconds: 30)),
    ]
    for (name, command) in steps {
        let begin = DispatchTime.now().uptimeNanoseconds
        try command.apply(to: &project)
        let table = try CutCompiler.compile(project, cut: project.cut!)
        let preview = try await builder.build(table: table, paths: paths, song: nil, fit: .fill)
        let total = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e6
        let issues = CutValidator.validate(project, cut: project.cut!)
        print(
            "  \(name.padding(toLength: 36, withPad: " ", startingAt: 0))"
                + String(format: "%6.1f ms (Vorschau %.1f ms)", total, preview.milliseconds)
                + (issues.isEmpty ? ", Schnitt gültig" : ", \(issues.count) Verstöße"))
    }
}

/// Prüft den Schnitt eines gespeicherten Projekts: Invarianten, Anker der Schnittpunkte, Refrain-Kopien (E1).
func validateCut(_ path: String) throws {
    let project = try load(path).project
    guard let cut = project.cut, let analysis = project.analysis else {
        throw ToolError(description: "Das Projekt hat noch keinen Schnitt.")
    }
    let issues = CutValidator.validate(project, cut: cut)
    print("Schnitt „\(cut.name)“: \(cut.shots.count) Einstellungen, Song \(Format.time(analysis.duration))")
    var anchors: [String: Int] = [:]
    for shot in cut.shots.dropFirst() {
        let kind = String(shot.start.anchor.description.prefix { $0 != ":" })
        anchors[kind, default: 0] += 1
    }
    print(
        "Schnittpunkte nach Anker: "
            + anchors.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    let free = anchors["free"] ?? 0
    print(free == 0 ? "Alle Schnitte liegen auf Ankern." : "\(free) Schnitte ohne Anker")
    let copies = cut.shots.filter { $0.reasons?.copiedFrom != nil }
    let repeats = analysis.sections.filter { $0.repeatOf != nil }
    print(
        "Wiederholte Abschnitte: \(repeats.count), kopierte Einstellungen: \(copies.count) (Modus \(project.style.refrainMode.title))"
    )
    let durations = cut.shots.map(\.duration).sorted()
    print(
        String(
            format: "Einstellungslänge: kürzeste %.2f s, Median %.2f s, längste %.2f s", durations.first ?? 0,
            durations[durations.count / 2], durations.last ?? 0))
    print("Clips verwendet: \(Set(cut.shots.map(\.clipID)).count) von \(project.clips.count)")
    if issues.isEmpty {
        print("Invarianten I1–I5: erfüllt")
    } else {
        for issue in issues { print("  ✗ \(issue)") }
        throw ToolError(description: "\(issues.count) Verstöße")
    }
}

/// Wie der Autopilot ohne App: Song analysieren, ins Projekt setzen, ersten Schnitt erzeugen, sichern. Mit Songtext
/// zusätzlich Gesang erkennen (Whisper), Wortzeiten korrigieren und den Text ausrichten.
func autocut(_ path: String, song: String, lyrics: String? = nil) async throws {
    var project = try load(path).project
    let start = DispatchTime.now().uptimeNanoseconds
    let output = try await SongAnalyzer().analyze(URL(fileURLWithPath: song))
    project.song = MediaRef(path: song)
    project.analysis = output.analysis
    if let lyrics {
        let text = try String(contentsOfFile: lyrics, encoding: .utf8)
        let raw = try await WhisperTranscriber().transcribe(path: song, language: "de")
        let audio = try await AudioDecoder.decodeMono(URL(fileURLWithPath: song))
        let corrected = WordTiming.correct(raw, spectrum: Spectrum(audio))
        project.lyricsText = text
        project.analysis = LyricsWorkflow.apply(transcript: corrected, lyrics: text, to: output.analysis)
        print("Songtext: \(project.analysis?.lines.count ?? 0) Zeilen, \(project.analysis?.words.count ?? 0) Wörter")
    }
    let analyzed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    try GenerateCut().apply(to: &project)
    let total = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    print(
        String(
            format: "Song %.0f s, %.1f BPM, %d Abschnitte (%.2f s); Schnitt mit %d Einstellungen nach %.2f s",
            output.analysis.duration, output.analysis.tempo, project.analysis?.sections.count ?? 0, analyzed,
            project.cut?.shots.count ?? 0, total))
    try ProjectFile.encode(project).write(to: URL(fileURLWithPath: path), options: .atomic)
}

/// Baut die Vorschau-Komposition eines Projekts und meldet Aufbauzeit, fehlende Dateien und Fehler.
@MainActor
func previewProject(_ path: String) async throws {
    let project = try load(path).project
    guard let cut = project.cut else { throw ToolError(description: "Das Projekt hat noch keinen Schnitt.") }
    let table = try CutCompiler.compile(project, cut: cut)
    let paths = Dictionary(project.clips.map { ($0.id, $0.media.path) }, uniquingKeysWith: { first, _ in first })
    let builder = PreviewBuilder()
    let preview = try await builder.build(
        table: table, paths: paths, song: project.song?.path, fit: project.timeline.fit)
    print(
        String(
            format: "Vorschau: %d Einstellungen, %.1f ms, Länge %.3f s (Tabelle %.3f s)", table.entries.count,
            preview.milliseconds, preview.composition.duration.seconds,
            FrameMath.seconds(ofFrames: table.durationFrames, rate: table.fps).doubleValue))
    if !preview.missing.isEmpty { print("Fehlende oder unlesbare Clips: \(preview.missing.joined(separator: ", "))") }
}
