import AppKit
import Foundation
import SyllaBeatAI
import SyllaBeatCore
import SyllaBeatModels

/// Anbieter aus der Kommandozeile: `apple`, `ollama=<modell>`, `anthropic[=<modell>]` (Schlüssel aus
/// `ANTHROPIC_API_KEY`), `openai=<adresse>|<modell>` (Schlüssel aus `OPENAI_API_KEY`).
func provider(_ spec: String) throws -> any LanguageModelProvider {
    let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
    let environment = ProcessInfo.processInfo.environment
    switch parts[0] {
    case "apple": return AppleIntelligenceProvider()
    case "ollama": return OllamaProvider(model: parts.count > 1 ? parts[1] : "qwen3:8b")
    case "anthropic":
        return AnthropicProvider(
            apiKey: environment["ANTHROPIC_API_KEY"] ?? "",
            model: parts.count > 1 ? parts[1] : AnthropicProvider.defaultModel)
    case "openai":
        let detail = (parts.count > 1 ? parts[1] : "http://localhost:1234|local").split(separator: "|").map(String.init)
        return OpenAICompatibleProvider(
            baseURL: URL(string: detail[0])!, apiKey: environment["OPENAI_API_KEY"],
            model: detail.count > 1 ? detail[1] : "")
    default: throw ToolError(description: "Unbekannter Anbieter „\(spec)“ (apple, ollama=…, anthropic, openai=…)")
    }
}

/// Storyboard-Stufe 1, mehrfach: Gültigkeit, Dauer, nachgefüllte Abschnitte. `--sichern` übernimmt das letzte
/// gültige Storyboard ins Projekt und schneidet neu (mit Storyboard-Ähnlichkeiten aus SigLIP 2).
func storyboardCommand(_ arguments: [String]) async throws {
    guard let path = arguments.first else { throw ToolError(description: "Projekt fehlt") }
    var runs = 1
    var spec = "apple"
    var save = false
    var brief: String?
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--laeufe":
            runs = Int(arguments[index + 1]) ?? 1
            index += 1
        case "--anbieter":
            spec = arguments[index + 1]
            index += 1
        case "--regie":
            brief = arguments[index + 1]
            index += 1
        case "--sichern": save = true
        default: throw ToolError(description: "Unbekannte Option \(arguments[index])")
        }
        index += 1
    }
    var project = try load(path).project
    if let brief { project.brief = brief }
    let model = try provider(spec)
    print("Anbieter: \(model.kind.title) · \(model.modelName) · \(project.analysis?.sections.count ?? 0) Abschnitte")
    var valid = 0
    var times: [Double] = []
    var last: Storyboard?
    for run in 1...runs {
        do {
            let result = try await StoryboardDirector.create(project, provider: model)
            valid += 1
            times.append(result.seconds)
            last = result.storyboard
            print(
                String(
                    format: "Lauf %2d: gültig, %.1f s, Versuche %d, nachgefüllt %d · %@", run, result.seconds,
                    result.attempts, result.filledIn.count, String(result.storyboard.idea.prefix(90))))
        } catch {
            print("Lauf \(String(format: "%2d", run)): FEHLER \(error.localizedDescription)")
        }
    }
    let sorted = times.sorted()
    print(
        String(
            format: "Ergebnis: %d/%d gültig (%.0f %%), Median %.1f s", valid, runs, 100 * Double(valid) / Double(runs),
            sorted.isEmpty ? 0 : sorted[sorted.count / 2]))
    if let last {
        for plan in last.sections {
            print("  \(plan.sectionID) [\(plan.pace.title)] \(plan.mood) · \(plan.searchTerms.joined(separator: ", "))")
        }
    }
    guard save, let last else { return }
    let embedder = try await SiglipEmbedder()
    let sceneIndex = SceneIndex(project: project, model: embedder.package.id)
    let sections = try await StoryScores.compute(last, index: sceneIndex) { try embedder.embed(text: $0) }
    try ApplyStoryboard(storyboard: last, textScores: TextScores(sections: sections)).apply(to: &project)
    try ProjectFile.encode(project).write(to: URL(fileURLWithPath: path), options: .atomic)
    print(
        "Storyboard übernommen, neu geschnitten: \(project.cut?.shots.count ?? 0) Einstellungen (\(sceneIndex.count) Szenen mit Embedding)"
    )
}

/// Blindvergleich: Schnitt ohne und mit Storyboard (gleicher Seed). Ergebnis: Kontaktbogen je Abschnitt mit zufällig
/// vertauschten Varianten (`vergleich.png`), Schlüssel getrennt (`schluessel.txt`), dazu die mittlere Ähnlichkeit der
/// gewählten Szenen zur Regieanweisung.
@MainActor
func compareStoryboard(_ path: String, brief: String, output: String) async throws {
    var base = try load(path).project
    base.brief = brief
    base.storyboard = nil
    var without = base
    try GenerateCut().apply(to: &without)
    let model = AppleIntelligenceProvider()
    let result = try await StoryboardDirector.create(base, provider: model)
    let embedder = try await SiglipEmbedder()
    let index = SceneIndex(project: base, model: embedder.package.id)
    let sections = try await StoryScores.compute(result.storyboard, index: index) { try embedder.embed(text: $0) }
    var with = base
    try GenerateCut().apply(to: &with)
    try ApplyStoryboard(storyboard: result.storyboard, textScores: TextScores(sections: sections)).apply(to: &with)

    let briefScores = index.similarities(query: try embedder.embed(text: brief))
    func mean(_ project: Project) -> Double {
        let values = (project.cut?.shots ?? []).compactMap { $0.sceneID.flatMap { briefScores[$0] } }
        return values.isEmpty ? 0 : Double(values.reduce(0, +)) / Double(values.count)
    }
    // Reihenfolge zufällig, aber reproduzierbar je Projekt.
    var random = SeededRandom([SeededRandom.hash(path), SeededRandom.hash(brief)])
    let swap = random.unit() < 0.5
    let variants = swap ? [with, without] : [without, with]
    let folder = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try renderSheet(base: base, storyboard: result.storyboard, variants: variants)
        .write(to: folder.appendingPathComponent("vergleich.png"))
    let key = """
        Variante 1: \(swap ? "mit" : "ohne") Storyboard
        Variante 2: \(swap ? "ohne" : "mit") Storyboard
        Ähnlichkeit zur Regieanweisung (SigLIP, Mittel): ohne \(String(format: "%.4f", mean(without))), mit \(String(format: "%.4f", mean(with)))
        """
    try key.write(to: folder.appendingPathComponent("schluessel.txt"), atomically: true, encoding: .utf8)
    print("Kontaktbogen: \(folder.appendingPathComponent("vergleich.png").path) (Schlüssel getrennt)")
}

/// Kontaktbogen: je Abschnitt eine Zeile mit Name, Text und Storyboard-Bildidee, darunter je Variante die Bilder.
@MainActor
func renderSheet(base: Project, storyboard: Storyboard, variants: [Project]) throws -> Data {
    let sections = (base.analysis?.sections ?? []).sorted { $0.start < $1.start }
    let thumbWidth: CGFloat = 160
    let thumbHeight: CGFloat = 90
    let columns = 10
    let rowHeight = thumbHeight + 8
    let headerHeight: CGFloat = 46
    let width = 120 + CGFloat(columns) * (thumbWidth + 4) + 20
    let height = 60 + CGFloat(sections.count) * (headerHeight + CGFloat(variants.count) * rowHeight + 10)
    let image = NSImage(size: NSSize(width: width, height: height))
    let cache = MediaCache()
    image.lockFocusFlipped(true)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    func text(_ string: String, _ point: NSPoint, size: CGFloat, bold: Bool = false, color: NSColor = .black) {
        let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        (string as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }
    text("Regieanweisung: \(base.brief)", NSPoint(x: 10, y: 12), size: 15, bold: true)
    text("Idee: \(storyboard.idea.prefix(170))", NSPoint(x: 10, y: 34), size: 12, color: .darkGray)
    var y: CGFloat = 60
    for section in sections {
        let plan = storyboard.plan(for: section.id)
        let lyrics = (base.analysis?.lines ?? []).filter {
            $0.start >= section.start - 0.5 && $0.start < section.end - 0.5
        }
        .map(\.text).joined(separator: " / ")
        text("\(section.label) (\(section.id))", NSPoint(x: 10, y: y), size: 13, bold: true)
        text(
            "Text: \(lyrics.isEmpty ? "instrumental" : String(lyrics.prefix(120)))  ·  Bildidee: \(plan?.imageIdea.prefix(90) ?? "–")",
            NSPoint(x: 10, y: y + 20), size: 11, color: .darkGray)
        y += headerHeight
        for (number, variant) in variants.enumerated() {
            text("Variante \(number + 1)", NSPoint(x: 10, y: y + thumbHeight / 2 - 8), size: 12, bold: true)
            let shots = (variant.cut?.shots ?? []).filter {
                $0.start.time >= section.start - 0.01 && $0.start.time < section.end - 0.01
            }
            for (column, shot) in shots.prefix(columns).enumerated() {
                guard let clip = variant.clip(withID: shot.clipID), let fingerprint = clip.media.fingerprint,
                    let scene = clip.scenes.first(where: { $0.id == shot.sceneID }) ?? clip.scenes.first,
                    let thumb = NSImage(contentsOf: cache.thumbnail(fingerprint: fingerprint, sceneStart: scene.start))
                else { continue }
                thumb.draw(
                    in: NSRect(
                        x: 120 + CGFloat(column) * (thumbWidth + 4), y: y, width: thumbWidth, height: thumbHeight),
                    from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            }
            y += rowHeight
        }
        y += 10
    }
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else { throw ToolError(description: "Kontaktbogen nicht erzeugt") }
    return png
}

/// Bildbeschreibungen für Clips ohne Beschreibung (F-12), mit Zeit je Clip; das Projekt wird nach jedem Clip gesichert.
func describeCommand(_ path: String, spec: String, limit: Int) async throws {
    var project = try load(path).project
    let model = try provider(spec)
    let cache = MediaCache()
    var times: [Double] = []
    var failures = 0
    for clip in project.clips where clip.description.isEmpty && !clip.scenes.isEmpty {
        guard times.count + failures < limit, let fingerprint = clip.media.fingerprint else { break }
        do {
            let result = try await ClipDescriber.describe(clip, provider: model) { scene in
                let url = cache.thumbnail(fingerprint: fingerprint, sceneStart: scene.start)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            times.append(result.seconds)
            if let index = project.clips.firstIndex(where: { $0.id == clip.id }) { project.clips[index] = result.clip }
            try ProjectFile.encode(project).write(to: URL(fileURLWithPath: path), options: .atomic)
            print(
                String(
                    format: "%@ · %.1f s · %@ · [%@] · %@", clip.name, result.seconds, result.clip.description,
                    result.clip.tags.joined(separator: ", "), result.clip.filenameSuggestion ?? "–"))
        } catch {
            failures += 1
            print("\(clip.name): FEHLER \(error.localizedDescription)")
        }
    }
    let sorted = times.sorted()
    print(
        String(
            format: "%d beschrieben, %d Fehler, Median %.1f s je Clip", times.count, failures,
            sorted.isEmpty ? 0 : sorted[sorted.count / 2]))
}
