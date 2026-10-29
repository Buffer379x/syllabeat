import AVFoundation
import AppKit
import Foundation
import Observation
import SyllaBeatAI
import SyllaBeatCore
import SyllaBeatMedia

/// Medienarbeit eines Dokumentfensters: Import, Analyse, Arbeitskopien, Bildsuche. Alles läuft als Aufgaben
/// in der Aufgabenzentrale; Ergebnisse landen sofort im Dokument (ein Abbruch verliert nur den laufenden Clip).
@MainActor
@Observable
final class MediaController {
    @ObservationIgnored private weak var document: ProjectDocument?
    @ObservationIgnored private let services: AppServices
    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored private let analyzer = ClipAnalyzer()
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// Clips, deren Analyse gerade läuft.
    private(set) var busyClips: Set<String> = []
    /// Erhöht sich, wenn neue Vorschaubilder im Zwischenspeicher liegen.
    private(set) var thumbnailGeneration = 0
    private(set) var sceneIndex: SceneIndex?
    /// Die Bildsuche berechnet gerade Embeddings; Treffer sind noch unvollständig.
    private(set) var preparingSearch = false
    /// Ergebnis der semantischen Suche: Clip-IDs nach Ähnlichkeit, `nil` ohne Bildsuche.
    private(set) var semanticRanking: [String]?
    /// Bei aktiver Bildsuche: Start der am besten passenden Szene je Clip (für das Vorschaubild).
    private(set) var matchedScenes: [String: Double] = [:]
    var message: String?

    static let model = ModelCatalog.siglip2

    init(document: ProjectDocument, services: AppServices) {
        self.document = document
        self.services = services
    }

    private var project: Project? { document?.project }

    // MARK: - Öffnen

    /// Beim Öffnen: verschobene Dateien über Bookmarks wiederfinden, fehlende Analysen und Embeddings nachholen.
    func start() {
        guard let project else { return }
        let relinked = MediaResolver.relinkByBookmarks(project.clips)
        var song = project.song
        if let current = song, !MediaResolver.exists(current), let found = MediaResolver.resolveBookmark(current) {
            song = found
        }
        if !relinked.isEmpty || song != project.song {
            document?.applyAnalysis { project in
                for index in project.clips.indices {
                    if let media = relinked[project.clips[index].id] { project.clips[index].media = media }
                }
                project.song = song
            }
            message = "\(relinked.count + (song != project.song ? 1 : 0)) verschobene Dateien wiedergefunden."
        }
        checkMissing()
        let pending = project.clips.filter {
            $0.scenes.isEmpty && !$0.meta.needsConversion && MediaResolver.exists($0.media)
        }
        if !pending.isEmpty { analyze(pending.map(\.id)) } else { refreshIndexAndEmbed() }
    }

    /// Clips, deren Datei fehlt (geprüft beim Öffnen und nach Import oder Neuverknüpfen).
    private(set) var missingClipIDs: Set<String> = []

    func checkMissing() {
        missingClipIDs = Set((project?.clips ?? []).filter { !MediaResolver.exists($0.media) }.map(\.id))
    }

    // MARK: - Import

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Clips oder Song hinzufügen"
        panel.prompt = "Hinzufügen"
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .audio, .folder]
        if panel.runModal() == .OK { importItems(panel.urls) }
    }

    /// Dateien und Ordner aus Drag-and-Drop oder Dialog: Videos werden Clips, die erste Audiodatei wird der Song.
    func importItems(_ urls: [URL]) {
        let includeSubfolders = UserDefaults.standard.object(forKey: "importSubfolders") as? Bool ?? true
        // Song: eine abgelegte Audiodatei, sonst – solange das Projekt keinen Song hat – die erste in einem Ordner.
        var audio = urls.first(where: FileScanner.isAudio)
        if audio == nil, project?.song == nil {
            audio = urls.filter(\.hasDirectoryPath).lazy.flatMap(FileScanner.audioFiles(in:)).first
        }
        if let audio { chooseSong(audio) }
        let analyzer = analyzer
        let existing = Set((project?.clips ?? []).map(\.media.path))
        services.jobs.submit("Clips einlesen", resource: .io) { [weak self] context in
            let owner = self
            let files = FileScanner.videos(in: urls, includeSubfolders: includeSubfolders)
                .filter { !existing.contains($0.path) }
            guard !files.isEmpty else { return }
            await context.progress(0, detail: "\(files.count) Dateien")
            var clips: [Clip] = []
            var failures: [String] = []
            for (number, url) in files.enumerated() {
                try Task.checkCancellation()
                do {
                    clips.append(try await analyzer.probe(url))
                } catch {
                    failures.append(url.lastPathComponent)
                }
                await context.progress(
                    Double(number + 1) / Double(files.count), detail: "\(number + 1) von \(files.count)")
            }
            let added = clips
            let skipped = failures
            await MainActor.run { owner?.add(added, skipped: skipped) }
        }
    }

    private func add(_ clips: [Clip], skipped: [String]) {
        guard let document else { return }
        let known = Set(document.project.clips.map(\.id))
        let fresh = clips.filter { !known.contains($0.id) }
        if !fresh.isEmpty, let error = document.run(AddClips(clips: fresh), undoManager: undoManager) {
            message = error
        }
        var notes: [String] = []
        if clips.count > fresh.count { notes.append("\(clips.count - fresh.count) schon im Projekt") }
        if !skipped.isEmpty {
            notes.append("\(skipped.count) nicht lesbar: \(skipped.prefix(3).joined(separator: ", "))")
        }
        let convertible = fresh.filter(\.meta.needsConversion).count
        if convertible > 0 {
            notes.append(convertible == 1 ? "1 braucht eine Arbeitskopie" : "\(convertible) brauchen eine Arbeitskopie")
        }
        if !notes.isEmpty { message = "\(fresh.count) Clips hinzugefügt (\(notes.joined(separator: "; ")))." }
        checkMissing()
        analyze(fresh.filter { !$0.meta.needsConversion }.map(\.id))
    }

    func chooseSong(_ url: URL) {
        guard let document else { return }
        do {
            let media = try ClipAnalyzer.mediaRef(for: url)
            if document.project.cut != nil, document.project.song?.fingerprint != media.fingerprint {
                message =
                    "Neuer Song gewählt. Analyse und Schnitt des alten Songs wurden verworfen (rückgängig mit ⌘Z)."
            }
            if let error = document.run(SetSong(song: media), undoManager: undoManager) { message = error }
        } catch {
            message = "Der Song ist nicht lesbar: \(error.localizedDescription)"
        }
    }

    // MARK: - Analyse

    /// Szenen, Vorschaubilder und Merkmale; bis zu vier Clips parallel.
    func analyze(_ clipIDs: [String]) {
        guard let project, !clipIDs.isEmpty else { return }
        let clips = project.clips.filter { clipIDs.contains($0.id) && !busyClips.contains($0.id) }
        guard !clips.isEmpty else { return }
        busyClips.formUnion(clips.map(\.id))
        let analyzer = analyzer
        let title = clips.count == 1 ? "\(clips[0].name) analysieren" : "\(clips.count) Clips analysieren"
        services.jobs.submit(title, resource: .io) { [weak self] context in
            let owner = self
            var done = 0
            defer { Task { @MainActor in owner?.busyClips.subtract(clips.map(\.id)) } }
            try await withThrowingTaskGroup(of: Clip?.self) { group in
                var queue = clips.makeIterator()
                func next() {
                    guard let clip = queue.next() else { return }
                    group.addTask { try? await analyzer.analyze(clip) }
                }
                for _ in 0..<4 { next() }
                while let result = try await group.next() {
                    done += 1
                    if let result { await owner?.store(result) }
                    await context.progress(
                        Double(done) / Double(clips.count), detail: "\(done) von \(clips.count) Clips")
                    try Task.checkCancellation()
                    next()
                }
            }
            await owner?.refreshIndexAndEmbed()
        }
    }

    private func store(_ analyzed: Clip) {
        document?.applyAnalysis { project in
            guard let index = project.clips.firstIndex(where: { $0.id == analyzed.id }) else { return }
            project.clips[index] = project.clips[index].mergingAnalysis(analyzed)
        }
        busyClips.remove(analyzed.id)
        thumbnailGeneration += 1
    }

    // MARK: - Arbeitskopien

    /// Erstellt eine Arbeitskopie (ProRes LT oder HEVC, bei VFR mit konstanter Rate) und ersetzt die Quelle des Clips.
    func createWorkingCopy(for clipID: String) {
        guard let clip = project?.clip(withID: clipID) else { return }
        guard let ffmpeg = FFmpeg.locate() else {
            message = FFmpegError.missing.localizedDescription
            return
        }
        let preset =
            FFmpeg.Preset(rawValue: UserDefaults.standard.string(forKey: "workingCopyPreset") ?? "") ?? .proResLT
        let source = URL(fileURLWithPath: (clip.original ?? clip.media).path)
        let output = FFmpeg.workingCopyURL(for: source)
        let rate: Rational? = clip.meta.isVFR == true ? Self.cfrRate(for: clip.meta.fps) : nil
        let analyzer = analyzer
        busyClips.insert(clipID)
        services.jobs.submit("Arbeitskopie: \(clip.name)", resource: .io) { [weak self] context in
            let owner = self
            defer { Task { @MainActor in owner?.busyClips.remove(clipID) } }
            try await ffmpeg.convert(source, to: output, preset: preset, constantRate: rate) { fraction in
                Task { await context.progress(fraction.map { $0 * 0.8 }, detail: "Umwandeln") }
            }
            await context.progress(0.85, detail: "Analysieren")
            var copy = try await analyzer.probe(output)
            copy = try await analyzer.analyze(copy)
            let converted = copy
            await MainActor.run {
                owner?.document?.applyAnalysis { project in
                    guard let index = project.clips.firstIndex(where: { $0.id == clipID }) else { return }
                    var updated = project.clips[index]
                    updated.original = updated.original ?? updated.media
                    updated.media = converted.media
                    updated.meta = converted.meta
                    updated.scenes = updated.mergingAnalysis(converted).scenes
                    project.clips[index] = updated
                }
                owner?.thumbnailGeneration += 1
            }
            await owner?.refreshIndexAndEmbed()
        }
    }

    /// Ganzzahlige Zielrate für CFR-Kopien variabler Clips (z. B. 29,97 → 30000/1001).
    static func cfrRate(for rate: Rational) -> Rational {
        MediaProbe.rationalRate(nominal: rate.doubleValue, minFrameDuration: .invalid)
    }

    // MARK: - Neu verknüpfen

    func presentRelinkPanel() {
        let panel = NSOpenPanel()
        panel.title = "Ordner mit den fehlenden Medien wählen"
        panel.prompt = "Neu verknüpfen"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url, let clips = project?.clips else { return }
        services.jobs.submit("Medien neu verknüpfen", resource: .io) { [weak self] _ in
            let owner = self
            let found = MediaResolver.relink(clips, in: folder)
            await MainActor.run {
                owner?.document?.applyAnalysis { project in
                    for index in project.clips.indices {
                        if let media = found[project.clips[index].id] { project.clips[index].media = media }
                    }
                }
                owner?.checkMissing()
                let missing = owner?.missingClipIDs.count ?? 0
                owner?.message =
                    "\(found.count) Dateien neu verknüpft" + (missing > 0 ? ", \(missing) fehlen weiter." : ".")
            }
        }
    }

    // MARK: - Bildsuche

    var searchAvailable: Bool { Self.model.isInstalled }

    /// Lädt vorhandene Embeddings und berechnet fehlende im Inferenzdienst.
    func refreshIndexAndEmbed() {
        guard let project, Self.model.isInstalled else { return }
        let missing = Set(SceneIndex.missing(in: project, model: Self.model.id))
        let clips = project.clips.filter { missing.contains($0.id) }
        reloadIndex()
        guard !clips.isEmpty else { return }
        preparingSearch = true
        let client = services.inference
        let model = Self.model
        services.jobs.submit("Bildsuche vorbereiten", resource: .inference, priority: .utility) { [weak self] context in
            let owner = self
            defer { Task { @MainActor in owner?.finishEmbedding() } }
            let cache = MediaCache()
            for (number, clip) in clips.enumerated() {
                try Task.checkCancellation()
                guard let fingerprint = clip.media.fingerprint else { continue }
                let url = cache.embeddings(fingerprint: fingerprint, model: model.id)
                var file = EmbeddingFile.read(url) ?? EmbeddingFile(model: model.id, dimension: model.dimension)
                let scenes = clip.scenes.filter { file.vectors[MediaCache.key(forSceneStart: $0.start)] == nil }
                let paths = scenes.map { cache.thumbnail(fingerprint: fingerprint, sceneStart: $0.start).path }
                let vectors = try await client.embedImages(model: model.id, paths: paths)
                for (scene, vector) in zip(scenes, vectors) where !vector.isEmpty {
                    file.vectors[MediaCache.key(forSceneStart: scene.start)] = vector
                }
                try file.write(to: url)
                await context.progress(
                    Double(number + 1) / Double(clips.count), detail: "\(number + 1) von \(clips.count) Clips")
                // Früh suchen können: Index alle 20 Clips nachladen.
                if number % 20 == 19 { await owner?.reloadIndex() }
            }
        }
    }

    private func finishEmbedding() {
        preparingSearch = false
        reloadIndex()
    }

    private func reloadIndex() {
        guard let project else { return }
        let model = Self.model.id
        Task.detached(priority: .utility) { [weak self] in
            let index = SceneIndex(project: project, model: model)
            await MainActor.run { self?.sceneIndex = index }
        }
    }

    /// Semantische Suche mit kurzer Verzögerung beim Tippen.
    func search(_ query: String) {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let index = sceneIndex, !index.isEmpty else {
            semanticRanking = nil
            matchedScenes = [:]
            return
        }
        let client = services.inference
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                let vector = try await client.embedText(model: Self.model.id, text: text)
                guard !Task.isCancelled else { return }
                let hits = index.rank(query: vector)
                self?.semanticRanking = hits.map(\.clipID)
                self?.matchedScenes = Dictionary(uniqueKeysWithValues: hits.map { ($0.clipID, $0.sceneStart) })
            } catch {
                self?.semanticRanking = nil
                self?.message = error.localizedDescription
            }
        }
    }
}
