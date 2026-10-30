import AVFoundation
import Foundation
import SyllaBeatAI
import SyllaBeatCore
import SyllaBeatMedia
import SyllaBeatModels

/// Text-Ähnlichkeiten wie in der App (`StoryScores.lineRows` je Zeile, Storyboard-Abschnitte, Zuschlag aus
/// Beschreibungen und Dateinamen).
func appTextScores(_ project: Project) async throws -> TextScores {
    guard let analysis = project.analysis else { return TextScores() }
    let embedder = try await SiglipEmbedder()
    let index = SceneIndex(project: project, model: embedder.package.id)
    guard !index.isEmpty else { return TextScores() }
    let descriptions = StoryScores.descriptions(of: project)
    let values = try await StoryScores.lineRows(analysis, descriptions: descriptions) { text in
        index.similarities(query: try embedder.embed(text: text))
    }
    var sections: [String: [String: Float]] = [:]
    if let storyboard = project.storyboard {
        sections = try await StoryScores.compute(storyboard, index: index, descriptions: descriptions) {
            try embedder.embed(text: $0)
        }
    }
    return TextScores(values, sections: sections)
}

/// Kapitel aus der Wahrheit setzen: Kapitel in `reihenfolge`, jeder Clip ins erste Kapitel, dessen Namensteile passen.
func applyTruthChapters(_ project: inout Project, _ truth: StoryTruth) {
    let order = truth.reihenfolge ?? truth.kapitel.keys.sorted()
    project.story.chapters = order.enumerated().map { index, name in
        Chapter(
            id: name, name: name, color: index,
            traits: truth.kapitelTageszeit?[name].map { [Trait.timeOfDay.id: $0] } ?? [:])
    }
    for index in project.clips.indices {
        let name = project.clips[index].name.lowercased()
        project.clips[index].chapterID = order.first { chapter in
            (truth.kapitel[chapter] ?? []).contains { name.contains($0.lowercased()) }
        }
    }
}

/// Drehbuch aus der Wahrheit (alle erwarteten Kapitel als Hauptkapitel).
func truthPlan(_ project: Project, _ truth: StoryTruth) -> [String: [String: ChapterRole]] {
    var plan: [String: [String: ChapterRole]] = [:]
    for section in project.analysis?.sections ?? [] {
        if let chapters = truth.abschnitte[section.label] {
            plan[section.id] = Dictionary(chapters.map { ($0, ChapterRole.main) }, uniquingKeysWith: { a, _ in a })
        }
    }
    return plan
}

/// `drehbuch <Projekt> <Wahrheit>`: Vorschlag ohne KI (Kapitel aus der Wahrheit) gegen die erwarteten Kapitel.
func drehbuchCommand(_ arguments: [String]) async throws {
    guard arguments.count >= 2 else { throw ToolError(description: "Aufruf: drehbuch <Projekt> <Wahrheit>") }
    var project = try load(arguments[0]).project
    let truth = try JSONDecoder().decode(StoryTruth.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
    applyTruthChapters(&project, truth)
    let rows = try await appTextScores(project).values
    let sections = project.analysis?.sections ?? []
    let montage =
        project.story.montage ?? Set(sections.compactMap(\.repeatOf) + sections.filter { $0.repeatOf != nil }.map(\.id))
    let plan = DrehbuchProposer.plan(
        sections: sections, chapters: project.story.chapters,
        evidence: StoryScores.chapterEvidence(project, rows: rows), montage: montage)
    var right = 0
    for section in sections.sorted(by: { $0.start < $1.start }) {
        let proposed = plan[section.id]?.first { $0.value == .main }?.key ?? "–"
        let expected = truth.abschnitte[section.label] ?? []
        let ok = expected.contains(proposed)
        if ok { right += 1 }
        print(
            "\(ok ? " " : "✗") \(section.label): \(proposed)\(montage.contains(section.id) ? " (Montage)" : "")   erwartet: \(expected.joined(separator: "/"))"
        )
    }
    print("Drehbuch-Vorschlag: \(right)/\(sections.count) Abschnitte richtig")
}

/// `geschichte <Projekt> <Wahrheit> [--seeds N]`: Kapitel-, Zeilentreue, Tageszeit-Wechsel und Sandwiches je Variante.
func storyCommand(_ arguments: [String]) async throws {
    guard arguments.count >= 2 else { throw ToolError(description: "Aufruf: geschichte <Projekt> <Wahrheit>") }
    let project = try load(arguments[0]).project
    let truth = try JSONDecoder().decode(StoryTruth.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
    var seeds = 5
    if let flag = arguments.firstIndex(of: "--seeds"), flag + 1 < arguments.count {
        seeds = Int(arguments[flag + 1]) ?? 5
    }
    let text = try await appTextScores(project)
    var story = project
    applyTruthChapters(&story, truth)
    story.story.plan = truthPlan(story, truth)
    let variants: [(String, Project, TextScores)] = [
        ("ohne Text", project, TextScores()), ("mit Text", project, text), ("mit Geschichte", story, text),
    ]
    print("Variante | Kapitel-Treffer | Zeilen-Treffer | Tag↔Abend | Sandwiches | Einstellungen")
    for (name, project, scores) in variants {
        var sum = StoryMeasurement(chapterHits: 0, lineHits: 0, timeSwitches: 0, sandwiches: 0, shots: 0)
        var started = DispatchTime.now().uptimeNanoseconds
        var milliseconds = 0.0
        for seed in 1...max(1, seeds) {
            var style = project.style
            style.seed = UInt64(seed)
            started = DispatchTime.now().uptimeNanoseconds
            guard let cut = CutEngine.generate(project, style: style, textScores: scores) else {
                throw ToolError(description: "Kein Schnitt für Seed \(seed)")
            }
            milliseconds += Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            let m = StoryMetrics.measure(project, cut: cut, truth: truth)
            if seed == Int(ProcessInfo.processInfo.environment["FOLGE_SEED"] ?? "1"), arguments.contains("--folge"),
                name == "mit Geschichte"
            {
                for finding in InconsistencyChecker.check(project, cut: cut) {
                    print("  ⚠ \(finding.message)")
                }
                let resolved = StoryResolver.resolve(project)
                for shot in cut.shots {
                    let clip = project.clip(withID: shot.clipID)
                    let section = project.analysis?.sections.first {
                        $0.start <= shot.start.time + 0.01 && shot.start.time + 0.01 < $0.end
                    }
                    let evening = truth.abend.contains { clip?.name.lowercased().contains($0) ?? false }
                    print(
                        String(
                            format: "  %6.1f %@ %@ %@ Stufe %@%@", shot.start.time, section?.label ?? "–",
                            evening ? "☾" : "☀", clip?.name ?? shot.clipID,
                            resolved[shot.clipID]?.traitLevels["tageszeit"].map(String.init) ?? "–",
                            shot.reasons?.relaxed.isEmpty == false ? " gelockert: \(shot.reasons!.relaxed)" : ""))
                }
            }
            sum.chapterHits += m.chapterHits
            sum.lineHits += m.lineHits
            sum.timeSwitches += m.timeSwitches
            sum.sandwiches += m.sandwiches
            sum.shots += m.shots
        }
        let n = Double(max(1, seeds))
        print(
            String(
                format: "%@ | %.0f %% | %.0f %% | %.1f | %.1f | %.0f (%.0f ms je Schnitt)", name,
                100 * sum.chapterHits / n, 100 * sum.lineHits / n, Double(sum.timeSwitches) / n,
                Double(sum.sandwiches) / n, Double(sum.shots) / n, milliseconds / n))
    }
}

/// `drehliste <Projekt> [<Wahrheit>]`: Was fehlt? Mit Wahrheit werden Kapitel und Drehbuch daraus gesetzt.
func shotListCommand(_ arguments: [String]) async throws {
    guard let path = arguments.first else { throw ToolError(description: "Aufruf: drehliste <Projekt> [<Wahrheit>]") }
    var project = try load(path).project
    if arguments.count > 1 {
        let truth = try JSONDecoder().decode(
            StoryTruth.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        applyTruthChapters(&project, truth)
        project.story.plan = truthPlan(project, truth)
    }
    let rows = try await appTextScores(project).values
    var confidence: [String: Double] = [:]
    for line in project.analysis?.lines ?? [] {
        if let row = rows[line.id] {
            confidence[line.text.trimmingCharacters(in: .whitespaces)] = CutEngine.gateConfidence(row)
        }
    }
    let report = CoverageAnalyzer.analyze(project, lineConfidence: confidence)
    print(ShotList.text(ShotList.entries(report, project: project)))
}

/// `render <Projekt> <Datei.mp4> [--hevc]`: fertiges Video des aktiven Schnitts, dazu YouTube-Kapitel und Prüfung von
/// Dauer und Bildanzahl gegen die Frame-Tabelle.
@MainActor
func renderCommand(_ arguments: [String]) async throws {
    guard arguments.count >= 2 else { throw ToolError(description: "Aufruf: render <Projekt> <Datei.mp4> [--hevc]") }
    let project = try load(arguments[0]).project
    guard let cut = project.cut else { throw ToolError(description: "Das Projekt hat noch keinen Schnitt.") }
    let table = try CutCompiler.compile(project, cut: cut)
    let paths = Dictionary(project.clips.map { ($0.id, $0.media.path) }, uniquingKeysWith: { first, _ in first })
    let target = URL(fileURLWithPath: arguments[1])
    let started = DispatchTime.now().uptimeNanoseconds
    try await VideoRenderer.render(
        table: table, paths: paths, song: project.song?.path, fit: project.timeline.fit,
        settings: RenderSettings(codec: arguments.contains("--hevc") ? .hevc : .h264), to: target, progress: { _ in })
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
    let asset = AVURLAsset(url: target)
    let duration = try await asset.load(.duration).seconds
    let expected = FrameMath.seconds(ofFrames: table.durationFrames, rate: table.fps).doubleValue
    let audio = try await asset.loadTracks(withMediaType: .audio).count
    print(
        String(
            format: "Video: %.3f s (Tabelle %.3f s, %lld Bilder bei %@ fps), Tonspuren %d, gerendert in %.1f s",
            duration, expected, table.durationFrames, "\(table.fps)", audio, seconds))
    if let chapters = YouTubeExport.chapters(project, cut: cut) { print("YouTube-Kapitel:\n\(chapters)") }
}
