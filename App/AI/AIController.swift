import Foundation
import Observation
import SyllaBeatAI
import SyllaBeatCore

/// KI eines Dokumentfensters: Bildbeschreibungen als fortsetzbare Hintergrundaufgabe (F-12) und das Storyboard
/// (F-13). Cloud-Anbieter brauchen vorher eine Zustimmung; der manuelle Anbieter zeigt den Prompt zum Kopieren.
@MainActor
@Observable
final class AIController {
    @ObservationIgnored private weak var document: ProjectDocument?
    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let media: MediaController
    @ObservationIgnored private let cut: CutController
    @ObservationIgnored var undoManager: UndoManager?

    /// Clips, die gerade beschrieben werden (eine Aufgabe zur Zeit).
    private(set) var describing = false
    private(set) var creatingStoryboard = false
    /// Nach neuen Beschreibungen bei vorhandenem Schnitt: Banner „Schnitt verbessern?“.
    var offerImprovement = false
    var message: String?

    /// Ausstehende Zustimmung für einen Cloud-Anbieter; danach läuft `action`.
    struct ConsentRequest: Identifiable {
        let id = UUID()
        var kind: ProviderKind
        var task: AITask
        var action: () -> Void
    }

    var consentRequest: ConsentRequest?

    /// Manueller Anbieter: Prompt zum Kopieren, Antwort wird geprüft und übernommen.
    struct ManualExchange: Identifiable {
        let id = UUID()
        var prompt: String
        var schema: JSONSchema
        var task: AITask
    }

    var manualExchange: ManualExchange?

    init(document: ProjectDocument, services: AppServices, media: MediaController, cut: CutController) {
        self.document = document
        self.services = services
        self.media = media
        self.cut = cut
    }

    private var project: Project? { document?.project }

    /// Clips, die noch keine Beschreibung haben (von Hand geschriebene bleiben unangetastet).
    var undescribed: [Clip] {
        (project?.clips ?? []).filter { $0.description.isEmpty && !$0.scenes.isEmpty && !$0.excluded }
    }

    // MARK: - Zustimmung

    /// Führt `action` aus, sofern der Anbieter lokal ist oder die Zustimmung vorliegt; sonst wird sie erfragt.
    private func withConsent(_ provider: any LanguageModelProvider, _ task: AITask, _ action: @escaping () -> Void) {
        if provider.capabilities.isCloud, !AISettings.hasConsent(provider.kind, task) {
            consentRequest = ConsentRequest(kind: provider.kind, task: task, action: action)
        } else {
            action()
        }
    }

    func grantConsent(_ request: ConsentRequest) {
        AISettings.setConsent(true, request.kind, request.task)
        consentRequest = nil
        request.action()
    }

    // MARK: - Bildbeschreibungen

    /// Automatisch nach der Analyse, wenn eingeschaltet und ein Anbieter mit Bildeingabe gewählt ist. Cloud-Anbieter
    /// starten nie von selbst.
    func autoDescribeIfReady() {
        guard AISettings.autoDescribe, !describing, media.busyClips.isEmpty, !cut.generating,
            let provider = AISettings.provider(for: .vision, client: services.inference), provider.capabilities.vision,
            provider.kind != .manual, !provider.capabilities.isCloud || AISettings.hasConsent(provider.kind, .vision),
            !undescribed.isEmpty
        else { return }
        describe(undescribed.map(\.id))
    }

    /// Beschreibt Clips nacheinander. Jedes Ergebnis landet sofort im Dokument; ein Abbruch oder Absturz verliert nur
    /// den laufenden Clip, beim nächsten Öffnen geht es mit den übrigen weiter.
    /// `replacing`: auch vorhandene Beschreibungen neu erzeugen (Knopf „Neu beschreiben“), sonst Zwischenspeicher nutzen.
    func describe(_ clipIDs: [String], replacing: Bool = false) {
        guard !describing, !clipIDs.isEmpty else { return }
        guard let provider = AISettings.provider(for: .vision, client: services.inference) else {
            message = "Für Bildbeschreibungen zuerst einen Anbieter wählen (Einstellungen → Anbieter)."
            return
        }
        guard provider.capabilities.vision, provider.kind != .manual else {
            message = "„\(provider.kind.title)“ kann keine Bilder beschreiben."
            return
        }
        withConsent(provider, .vision) { [weak self] in
            self?.runDescriptions(clipIDs, provider: provider, replacing: replacing)
        }
    }

    private func runDescriptions(_ clipIDs: [String], provider: any LanguageModelProvider, replacing: Bool) {
        describing = true
        let hadCut = project?.cut != nil
        let resource = AISettings.resource(for: provider)
        services.jobs.submit("Clips beschreiben", resource: resource, priority: .utility) { [weak self] context in
            let owner = self
            defer { Task { @MainActor in owner?.finishDescriptions(hadCut: hadCut) } }
            let cache = MediaCache()
            var done = 0
            var failures = 0
            for (number, id) in clipIDs.enumerated() {
                try Task.checkCancellation()
                guard let clip = await MainActor.run(body: { owner?.project?.clip(withID: id) }),
                    let fingerprint = clip.media.fingerprint
                else { continue }
                await context.progress(
                    Double(number) / Double(clipIDs.count), detail: "\(number + 1) von \(clipIDs.count): \(clip.name)")
                // Schon einmal beschrieben (z. B. vor einem Absturz): aus dem Zwischenspeicher übernehmen.
                if !replacing, let stored = ClipDescriber.stored(clip, cache: cache) {
                    done += 1
                    await MainActor.run { owner?.store(stored.apply(to: clip), replacing: replacing) }
                    continue
                }
                do {
                    let result = try await ClipDescriber.describe(clip, provider: provider) { scene in
                        let url = cache.thumbnail(fingerprint: fingerprint, sceneStart: scene.start)
                        return FileManager.default.fileExists(atPath: url.path) ? url : nil
                    }
                    ClipDescriber.store(result.clip, cache: cache)
                    done += 1
                    await MainActor.run { owner?.store(result.clip, replacing: replacing) }
                } catch let error as ProviderError {
                    // Anbieter nicht erreichbar oder falsch eingerichtet: nicht für jeden Clip erneut versuchen.
                    if case .invalidAnswer = error {
                        failures += 1
                    } else {
                        throw error
                    }
                } catch is ClipDescriber.NoImages {
                    failures += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures += 1
                }
            }
            let summary = "\(done) Clips beschrieben" + (failures > 0 ? ", \(failures) übersprungen." : ".")
            await MainActor.run { owner?.message = summary }
        }
    }

    /// Übernimmt nur die Felder der Beschreibung, damit gleichzeitige Änderungen (Bewertung usw.) erhalten bleiben.
    /// Hat jemand inzwischen selbst eine Beschreibung geschrieben, bleibt sie (außer bei „Neu beschreiben“).
    private func store(_ described: Clip, replacing: Bool) {
        document?.applyAnalysis { project in
            guard let index = project.clips.firstIndex(where: { $0.id == described.id }),
                replacing || project.clips[index].description.isEmpty
            else { return }
            project.clips[index].description = described.description
            project.clips[index].mood = described.mood
            project.clips[index].tags = described.tags
            project.clips[index].filenameSuggestion = described.filenameSuggestion
            project.clips[index].visionModel = described.visionModel
            for scene in described.scenes {
                if let position = project.clips[index].scenes.firstIndex(where: { $0.id == scene.id }) {
                    project.clips[index].scenes[position].description = scene.description
                }
            }
        }
    }

    private func finishDescriptions(hadCut: Bool) {
        describing = false
        if hadCut, project?.cut != nil { offerImprovement = true }
    }

    /// „Schnitt mit neuen Beschreibungen verbessern“: Ähnlichkeiten neu berechnen und neu schneiden, fixierte
    /// Shots bleiben.
    func improveCut() {
        offerImprovement = false
        Task {
            await cut.refreshTextScores()
            cut.generate()
        }
    }

    // MARK: - Storyboard

    func createStoryboard() {
        guard let project, project.analysis != nil, !creatingStoryboard else { return }
        guard let provider = AISettings.provider(for: .director, client: services.inference) else {
            message = "Für die Regie zuerst einen Anbieter wählen (Einstellungen → Anbieter)."
            return
        }
        if provider.kind == .manual {
            do {
                let request = try StoryboardDirector.request(for: project)
                manualExchange = ManualExchange(
                    prompt: ManualProvider.transcript(request), schema: request.schema!, task: .director)
            } catch {
                message = error.localizedDescription
            }
            return
        }
        withConsent(provider, .director) { [weak self] in self?.runStoryboard(provider) }
    }

    private func runStoryboard(_ provider: any LanguageModelProvider) {
        guard let project else { return }
        creatingStoryboard = true
        let resource = AISettings.resource(for: provider)
        services.jobs.submit("Storyboard erstellen", resource: resource, priority: .userInitiated) {
            [weak self] context in
            let owner = self
            defer { Task { @MainActor in owner?.creatingStoryboard = false } }
            await context.progress(nil, detail: provider.modelName)
            let result = try await StoryboardDirector.create(project, provider: provider)
            await owner?.apply(result.storyboard)
            await MainActor.run {
                owner?.message =
                    "Storyboard von \(provider.modelName) in \(Int(result.seconds.rounded())) s"
                    + (result.filledIn.isEmpty ? "." : "; \(result.filledIn.count) Abschnitte mit Standardwerten.")
            }
        }
    }

    /// Eingefügte Antwort des manuellen Anbieters prüfen; liefert die Abweichungen (leer heißt übernommen).
    func submitManualAnswer(_ text: String, for exchange: ManualExchange) async -> [String] {
        let (data, problems) = StructuredGeneration.parse(text, schema: exchange.schema)
        guard let data, problems.isEmpty, let project else {
            return problems.isEmpty ? ["kein JSON gefunden"] : problems
        }
        do {
            let (storyboard, _) = try StoryboardDirector.storyboard(from: data, project: project, model: "manuell")
            manualExchange = nil
            await apply(storyboard)
            return []
        } catch {
            return [error.localizedDescription]
        }
    }

    /// Storyboard mit seinen Ähnlichkeiten übernehmen und neu schneiden (ein Undo-Schritt).
    func apply(_ storyboard: Storyboard?) async {
        guard let project else { return }
        let scores = await cut.scores(for: storyboard, in: project)
        errorFromRun(ApplyStoryboard(storyboard: storyboard, textScores: scores))
        await cut.refreshTextScores()
    }

    private func errorFromRun(_ command: some EditCommand) {
        if let error = document?.run(command, undoManager: undoManager) { message = error }
    }
}
