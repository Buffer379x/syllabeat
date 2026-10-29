import AVFoundation
import Foundation
import Observation
import SyllaBeatAI
import SyllaBeatCore
import SyllaBeatMedia

/// Schnitt eines Dokumentfensters: Autopilot, Stil, Neu würfeln, Varianten, Auswahl in der Bildspur und die
/// Vorschau-Komposition. Befehle laufen über das Dokument und landen auf dem Undo-Stapel.
@MainActor
@Observable
final class CutController {
    @ObservationIgnored private weak var document: ProjectDocument?
    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let media: MediaController
    @ObservationIgnored private let playback: Playback
    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored private let builder = PreviewBuilder()
    @ObservationIgnored private var previewKey: PreviewKey?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    /// Text-Embeddings je Zeilentext (bleiben, solange das Fenster offen ist).
    @ObservationIgnored private var lineVectors: [String: [Float]] = [:]
    @ObservationIgnored private var autopilotKey: String?

    /// Ausgewählte Einstellungen (Bildspur, Inspektor).
    var selection: Set<String> = []
    /// Ähnlichkeit Textzeile ↔ Szene (SigLIP 2); leer, solange die Bildsuche nicht bereit ist.
    private(set) var textScores = TextScores()
    private(set) var generating = false
    /// Warum die Vorschau kein Bild zeigt (Schnitt passt nicht mehr, Dateien fehlen).
    private(set) var previewProblem: String?
    private(set) var previewMissing: [String] = []
    private(set) var previewMilliseconds: Double?
    var errorMessage: String?

    init(document: ProjectDocument, services: AppServices, media: MediaController, playback: Playback) {
        self.document = document
        self.services = services
        self.media = media
        self.playback = playback
    }

    private var project: Project? { document?.project }

    var selectedShot: Shot? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return project?.cut?.shots.first { $0.id == id }
    }

    /// Schneiden ist möglich: Song analysiert und mindestens ein Clip mit Szenen.
    var canCut: Bool {
        guard let project, project.analysis != nil else { return false }
        return project.clips.contains { !$0.excluded && !$0.scenes.isEmpty && !$0.meta.needsConversion }
    }

    // MARK: - Befehle

    func run(_ command: some EditCommand) {
        errorMessage = document?.run(command, undoManager: undoManager)
    }

    func generate() { run(GenerateCut(textScores: textScores)) }
    func reroll() { run(Reroll(textScores: textScores)) }
    func createVariants() { run(CreateVariants(textScores: textScores)) }
    func selectVariant(_ id: String) { run(SelectVariant(variantID: id)) }
    func setStyle(_ style: CutStyle) { run(SetCutStyle(style: style, textScores: textScores)) }

    func recutSelection() {
        guard !selection.isEmpty else { return }
        run(RecutShots(shotIDs: selection, textScores: textScores))
    }

    /// `L`: Auswahl fixieren bzw. lösen, wenn schon alle fixiert sind.
    func toggleLockSelection() {
        guard let shots = project?.cut?.shots.filter({ selection.contains($0.id) }), !shots.isEmpty else { return }
        run(SetShotsLocked(shotIDs: selection, locked: !shots.allSatisfy(\.locked)))
    }

    /// Nach dem Neuberechnen sind die Shot-IDs neu vergeben: Die Auswahl folgt den Startzeiten.
    func remapSelection(from old: Cut?, to new: Cut?) {
        guard !selection.isEmpty else { return }
        let starts = Set((old?.shots ?? []).filter { selection.contains($0.id) }.map(\.start.time))
        selection = Set((new?.shots ?? []).filter { starts.contains($0.start.time) }.map(\.id))
    }

    // MARK: - Autopilot

    /// Sobald der Song analysiert ist und keine Clipanalyse oder Embedding-Berechnung mehr läuft, entsteht der erste
    /// Schnitt ohne Klick. Er landet nicht auf dem Undo-Stapel, sonst würde „Rückgängig“ ihn sofort neu auslösen.
    func autopilotIfReady() {
        guard let project, project.cut == nil, canCut, !generating else { return }
        guard media.busyClips.isEmpty, !media.preparingSearch else { return }
        let key = "\(project.clips.count)#\(project.analysis?.duration ?? 0)"
        guard autopilotKey != key else { return }
        autopilotKey = key
        generating = true
        Task {
            defer { generating = false }
            await refreshTextScores()
            guard let document, document.project.cut == nil else { return }
            var failure: String?
            let scores = textScores
            document.applyAnalysis { project in
                do {
                    try GenerateCut(textScores: scores).apply(to: &project)
                } catch {
                    failure = error.localizedDescription
                }
            }
            errorMessage = failure
        }
    }

    // MARK: - Text ↔ Bild

    /// Ähnlichkeiten für die Engine (SigLIP 2 im Inferenzdienst): jede Textzeile und, mit Storyboard, die
    /// Suchbegriffe jedes Abschnitts gegen alle Szenen; Beschreibungen geben einen Zuschlag. Ohne Bildsuche bleibt
    /// alles leer und die Engine schneidet nach Energie, Ästhetik und Abwechslung.
    func refreshTextScores() async {
        guard let project else { return }
        textScores = await scores(for: project.storyboard, in: project)
    }

    func scores(for storyboard: Storyboard?, in project: Project) async -> TextScores {
        guard let analysis = project.analysis, MediaController.model.isInstalled, let index = media.sceneIndex,
            !index.isEmpty
        else { return TextScores() }
        let descriptions = StoryScores.descriptions(of: project)
        var values: [String: [String: Float]] = [:]
        for line in analysis.lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let vector = await embed(text) else { continue }
            var row = index.similarities(query: vector)
            StoryScores.addBonus(to: &row, words: StoryScores.words(text), descriptions: descriptions)
            values[line.id] = row
        }
        var sections: [String: [String: Float]] = [:]
        if let storyboard {
            sections =
                (try? await StoryScores.compute(storyboard, index: index, descriptions: descriptions) { text in
                    await self.embed(text) ?? []
                }) ?? [:]
        }
        return TextScores(values, sections: sections)
    }

    /// Text-Embedding mit Zwischenspeicher (gleicher Text, gleicher Vektor).
    private func embed(_ text: String) async -> [Float]? {
        if let cached = lineVectors[text] { return cached }
        let vector = try? await services.inference.embedText(model: MediaController.model.id, text: text)
        if let vector { lineVectors[text] = vector }
        return vector
    }

    // MARK: - Vorschau

    private struct PreviewKey: Equatable {
        var table: FrameTable
        var paths: [String: String]
        var song: String?
        var fit: TimelineSettings.Fit
    }

    /// Baut die Vorschau neu, wenn sich Frame-Tabelle, Dateien oder Bildanpassung geändert haben (sonst nichts).
    func updatePreview() {
        guard let project else { return }
        guard let cut = project.cut else {
            previewKey = nil
            previewProblem = nil
            previewMissing = []
            playback.showSongOnly()
            return
        }
        let table: FrameTable
        do {
            table = try CutCompiler.compile(project, cut: cut)
        } catch {
            previewKey = nil
            previewProblem = error.localizedDescription
            playback.showSongOnly()
            return
        }
        previewProblem = nil
        let used = Set(table.entries.map(\.clipID))
        var paths: [String: String] = [:]
        for clip in project.clips where used.contains(clip.id) { paths[clip.id] = clip.media.path }
        let key = PreviewKey(table: table, paths: paths, song: project.song?.path, fit: project.timeline.fit)
        guard key != previewKey else { return }
        previewKey = key
        previewTask?.cancel()
        previewTask = Task {
            do {
                let preview = try await builder.build(table: table, paths: paths, song: key.song, fit: key.fit)
                guard !Task.isCancelled, previewKey == key else { return }
                playback.show(preview.composition, video: preview.videoComposition)
                previewMissing = preview.missing
                previewMilliseconds = preview.milliseconds
                Log.media.info("Vorschau aufgebaut: \(table.entries.count) Shots in \(Int(preview.milliseconds)) ms")
            } catch {
                guard previewKey == key else { return }
                previewProblem = "Die Vorschau ließ sich nicht aufbauen: \(error.localizedDescription)"
                playback.showSongOnly()
            }
        }
    }

    /// Nach Neuverknüpfen oder neuer Arbeitskopie: Dateien neu laden.
    func forget(paths: [String]) {
        for path in paths { builder.forget(path) }
        previewKey = nil
        updatePreview()
    }
}
