import Foundation
import SyllaBeatAI
import SyllaBeatCore
import SyllaBeatModels

/// Text-Ähnlichkeiten wie in der App (SigLIP 2 je Zeile und Storyboard-Abschnitt, Zuschlag aus Beschreibungen).
func appTextScores(_ project: Project) async throws -> TextScores {
    guard let analysis = project.analysis else { return TextScores() }
    let embedder = try await SiglipEmbedder()
    let index = SceneIndex(project: project, model: embedder.package.id)
    guard !index.isEmpty else { return TextScores() }
    let descriptions = StoryScores.descriptions(of: project)
    var values: [String: [String: Float]] = [:]
    for line in analysis.lines {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        var row = index.similarities(query: try embedder.embed(text: text))
        StoryScores.addBonus(to: &row, words: StoryScores.words(text), descriptions: descriptions)
        values[line.id] = row
    }
    var sections: [String: [String: Float]] = [:]
    if let storyboard = project.storyboard {
        sections = try await StoryScores.compute(storyboard, index: index, descriptions: descriptions) {
            try embedder.embed(text: $0)
        }
    }
    return TextScores(values, sections: sections)
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
    let variants: [(String, TextScores)] = [("ohne Text", TextScores()), ("mit Text", text)]
    print("Variante | Kapitel-Treffer | Zeilen-Treffer | Tag↔Abend | Sandwiches | Einstellungen")
    for (name, scores) in variants {
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
