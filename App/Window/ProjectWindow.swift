import AppKit
import SwiftUI
import SyllaBeatCore
import SyllaBeatUI

/// Ein Dokumentfenster. Legt beim ersten Erscheinen den Medien-Controller des Dokuments an.
struct ProjectWindow: View {
    @ObservedObject var document: ProjectDocument
    @Environment(AppServices.self) private var services
    @State private var media: MediaController?
    @State private var song: SongController?
    @State private var cut: CutController?
    @State private var ai: AIController?

    var body: some View {
        if let media, let song, let cut, let ai {
            ProjectWorkspace(document: document, media: media, song: song, cut: cut, ai: ai)
        } else {
            Color.clear.onAppear {
                let media = MediaController(document: document, services: services)
                let song = SongController(document: document, services: services)
                let cut = CutController(document: document, services: services, media: media, playback: song.playback)
                self.media = media
                self.song = song
                self.cut = cut
                ai = AIController(document: document, services: services, media: media, cut: cut)
            }
        }
    }
}

/// Bibliothek, Vorschau, Inspektor und darunter die Timeline über die volle Breite.
struct ProjectWorkspace: View {
    @ObservedObject var document: ProjectDocument
    var media: MediaController
    var song: SongController
    var cut: CutController
    var ai: AIController
    @Environment(\.undoManager) private var undoManager
    @Environment(\.documentConfiguration) private var configuration
    @State private var selectedClipIDs: Set<String> = []
    private var selectedClipID: String? { selectedClipIDs.count == 1 ? selectedClipIDs.first : nil }
    @State private var showsInspector = true
    @State private var backupNotice: String?
    @State private var errorMessage: String?
    @AppStorage("onboarding.done") private var onboardingDone = false
    @State private var showsWelcome = false
    /// Format-Vorschlag, den der Nutzer weggeklickt hat (gilt bis zum Schließen des Fensters).
    @State private var dismissedFormat: TimelineSettings?

    private var project: Project { document.project }

    var body: some View {
        // Das Banner steht über den Splits: AppKit-Splitviews beachten keine Safe-Area-Einschübe.
        VStack(spacing: 0) {
            if let backupNotice {
                Banner(text: backupNotice, systemImage: "clock.arrow.circlepath", identifier: "migrationBanner") {
                    self.backupNotice = nil
                }
            }
            if let message = media.message {
                Banner(text: message, systemImage: "info.circle", identifier: "mediaBanner") { media.message = nil }
            }
            if let message = song.message {
                Banner(text: message, systemImage: "music.note", identifier: "songBanner") { song.message = nil }
            }
            if let message = ai.message {
                Banner(text: message, systemImage: "sparkles", identifier: "aiBanner") { ai.message = nil }
            }
            if let hint = formatHint, let suggested = formatSuggestion {
                Banner(
                    text: hint, systemImage: "film.stack", identifier: "formatBanner",
                    actionTitle: "Auf \(Format.fps(suggested.fps)) fps umstellen",
                    action: {
                        errorMessage = document.run(SetTimelineSettings(settings: suggested), undoManager: undoManager)
                    }
                ) { dismissedFormat = suggested }
            }
            if showsChapterBanner {
                Banner(
                    text: "Erzählen deine Clips eine Geschichte? Mit Kapiteln folgt der Schnitt ihrer Reihenfolge.",
                    systemImage: "book", identifier: "chapterBanner", actionTitle: "Kapitel anlegen",
                    action: { cut.showsDrehbuch = true }
                ) { run(SetAsksForChapters(false)) }
            }
            if ai.offerImprovement {
                Banner(
                    text:
                        "Neue Bildbeschreibungen liegen vor. Schnitt damit verbessern? Fixierte Einstellungen bleiben.",
                    systemImage: "wand.and.stars", identifier: "improveBanner", actionTitle: "Verbessern",
                    action: { ai.improveCut() }
                ) { ai.offerImprovement = false }
            }
            VSplitView {
                HSplitView {
                    LibraryPane(
                        project: project, media: media, selection: $selectedClipIDs,
                        assign: { ids, chapter in
                            run(
                                AssignChapter(
                                    clipIDs: ids, chapterID: chapter, includeTakes: false, textScores: cut.textScores))
                        },
                        createChapter: { name, ids in createChapter(name, ids) },
                        setTime: { ids, value in
                            run(
                                SetTraitValue(
                                    clipIDs: ids, traitID: Trait.timeOfDay.id, value: value, textScores: cut.textScores)
                            )
                        }
                    ) { id in
                        selectedClipIDs = [id]
                        cut.view(clipID: id)
                    }
                    .frame(minWidth: 220, idealWidth: 270, maxWidth: 460)
                    Group {
                        if let id = cut.viewedClipID, let clip = project.clip(withID: id) {
                            ClipViewer(
                                clip: clip, player: cut.clipPlayer,
                                run: { errorMessage = document.run($0, undoManager: undoManager) },
                                step: { stepViewedClip($0) }, close: { cut.view(clipID: nil) })
                        } else {
                            PreviewPane(project: project, playback: song.playback, cut: cut)
                        }
                    }
                    .frame(minWidth: 380, maxWidth: .infinity)
                    if showsInspector {
                        InspectorPane(
                            document: document, media: media, song: song, cut: cut, ai: ai,
                            selectedClipID: selectedClipID, selectedClipIDs: selectedClipIDs,
                            errorMessage: $errorMessage
                        )
                        .frame(minWidth: 250, idealWidth: 290, maxWidth: 460)
                    }
                }
                .frame(minHeight: 320, maxHeight: .infinity)
                TimelinePane(project: project, song: song, cut: cut, markers: project.inconsistencyMarkers) { command in
                    errorMessage = document.run(command, undoManager: undoManager)
                }
                .frame(
                    minHeight: 120, idealHeight: TimelineCanvas.totalHeight + 50,
                    maxHeight: TimelineCanvas.totalHeight + 60)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            media.importItems(urls)
            return true
        }
        .background(
            WindowAccessor { window in
                document.markChanged = { [weak window] in
                    NSDocumentController.shared.document(for: window ?? NSWindow())?.updateChangeCount(.changeDone)
                }
            }
        )
        .focusedSceneValue(\.projectMedia, media)
        .focusedSceneValue(\.projectCut, cut)
        .onDeleteCommand(perform: removeSelectedClip)
        .toolbar { toolbar }
        .navigationSubtitle(subtitle)
        .task(id: configuration?.fileURL) { createLegacyBackupIfNeeded() }
        .task {
            // Willkommen einmal beim ersten Start; nicht bei automatischen Abläufen (UI-Tests, -SBOpenDocument).
            if !onboardingDone, UserDefaults.standard.string(forKey: "SBOpenDocument") == nil { showsWelcome = true }
            media.undoManager = undoManager
            cut.undoManager = undoManager
            ai.undoManager = undoManager
            media.start()
            song.songChanged()
            // Automatisierung (UI-Tests): `-SBImportPaths "<Pfad>|<Pfad>"` importiert beim Öffnen.
            if let paths = UserDefaults.standard.string(forKey: "SBImportPaths") {
                media.importItems(paths.split(separator: "|").map { URL(fileURLWithPath: String($0)) })
            }
        }
        .onChange(of: undoManager) { _, manager in
            media.undoManager = manager
            cut.undoManager = manager
            ai.undoManager = manager
        }
        .onChange(of: project.song) { _, _ in song.songChanged() }
        // Autopilot: erster Schnitt, sobald Song und Clips fertig analysiert sind.
        .onChange(of: autopilotSignal, initial: true) { _, _ in
            cut.autopilotIfReady()
            // Beschreibungen erst nach dem ersten Schnitt (oder wenn es keinen geben kann), damit er nicht wartet.
            if project.cut != nil || !cut.canCut { ai.autoDescribeIfReady() }
        }
        .onChange(of: project.cut == nil) { _, _ in ai.autoDescribeIfReady() }
        .sheet(item: Bindable(ai).consentRequest) { request in
            ConsentSheet(request: request) {
                ai.grantConsent(request)
            } cancel: {
                ai.consentRequest = nil
            }
        }
        .sheet(isPresented: $showsWelcome) {
            WelcomeSheet {
                onboardingDone = true
                showsWelcome = false
            }
        }
        .sheet(isPresented: Bindable(cut).showsDrehbuch) {
            DrehbuchSheet(project: project, textScores: cut.textScores, run: { run($0) }) {
                cut.showsDrehbuch = false
            }
        }
        .sheet(isPresented: Bindable(cut).showsExport) {
            ExportSheet(project: project) { cut.showsExport = false }
        }
        .sheet(item: Bindable(ai).manualExchange) { exchange in
            ManualExchangeSheet(exchange: exchange, ai: ai)
        }
        .onChange(of: previewSignal, initial: true) { _, _ in cut.updatePreview() }
        .task(id: textSignal) { await cut.refreshTextScores() }
        // Clip oder Einstellung: Der Inspektor zeigt immer nur eines davon.
        .onChange(of: selectedClipIDs) { _, ids in if !ids.isEmpty { cut.selection = [] } }
        .onChange(of: cut.selection) { _, ids in if !ids.isEmpty { selectedClipIDs = [] } }
        .onChange(of: project.cut) { old, new in cut.remapSelection(from: old, to: new) }
        .alert(
            "Aktion nicht möglich",
            isPresented: Binding(
                get: { errorMessage != nil || cut.errorMessage != nil },
                set: { _ in
                    errorMessage = nil
                    cut.errorMessage = nil
                })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? cut.errorMessage ?? "")
        }
    }

    private var autopilotSignal: String {
        "\(project.analysis != nil)#\(project.clips.count)#\(project.clips.filter { !$0.scenes.isEmpty }.count)#"
            + "\(media.busyClips.isEmpty)#\(media.preparingSearch)"
    }

    private struct PreviewSignal: Equatable {
        var cut: Cut?
        var timeline: TimelineSettings
        var paths: [String]
        var song: MediaRef?
        var duration: Double?
    }

    private var previewSignal: PreviewSignal {
        PreviewSignal(
            cut: project.cut, timeline: project.timeline, paths: project.clips.map(\.media.path), song: project.song,
            duration: project.analysis?.duration)
    }

    /// Ändert sich, wenn die Ähnlichkeiten für die Engine neu zu berechnen sind (Bildsuche, Text, Storyboard,
    /// Beschreibungen).
    private var textSignal: String {
        let lines = project.analysis?.lines.map(\.text).joined(separator: "|") ?? ""
        let terms = project.storyboard?.sections.flatMap(\.searchTerms).joined(separator: "|") ?? ""
        let described = project.clips.filter { !$0.description.isEmpty }.count
        return "\(media.sceneIndex?.count ?? 0)#\(lines)#\(terms)#\(described)"
    }

    /// Banner nach dem ersten Schnitt, solange es keine Kapitel gibt (ab 10 Clips).
    private var showsChapterBanner: Bool {
        project.story.asksForChapters && project.story.chapters.isEmpty && project.clips.count >= 10
            && project.cut != nil
    }

    private func run(_ command: some EditCommand) {
        errorMessage = document.run(command, undoManager: undoManager)
    }

    /// Neues Kapitel am Ende der Erzählreihenfolge, die Clips kommen hinein.
    private func createChapter(_ name: String, _ ids: Set<String>) {
        let chapter = Chapter(
            id: "k-\(UUID().uuidString.prefix(8).lowercased())", name: name, color: project.story.chapters.count)
        run(SetChapters(chapters: project.story.chapters + [chapter], textScores: cut.textScores))
        if !ids.isEmpty {
            run(AssignChapter(clipIDs: ids, chapterID: chapter.id, includeTakes: false, textScores: cut.textScores))
        }
    }

    /// ↑/↓ in der Clip-Ansicht: voriger/nächster Clip in Bibliotheksreihenfolge.
    private func stepViewedClip(_ offset: Int) {
        guard let id = cut.viewedClipID, let index = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let next = index + offset
        guard project.clips.indices.contains(next) else { return }
        selectedClipIDs = [project.clips[next].id]
        cut.view(clipID: project.clips[next].id)
    }

    /// Vorschlag für das Timeline-Format, sobald alle Clips eingelesen sind; nie automatisch übernommen.
    private var formatSuggestion: TimelineSettings? {
        guard !project.clips.isEmpty, media.busyClips.isEmpty else { return nil }
        let suggested = TimelineSettings.suggested(for: project.clips, current: project.timeline)
        guard suggested != project.timeline, suggested != dismissedFormat else { return nil }
        return suggested
    }

    private var formatHint: String? {
        formatSuggestion == nil ? nil : TimelineSettings.hint(for: project.clips, current: project.timeline)
    }

    private var subtitle: String {
        let fps = Format.fps(project.timeline.fps)
        return "\(project.timeline.width)×\(project.timeline.height) · \(fps) fps"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            StatusChips(project: project)
            InconsistencyChip(project: project, cut: cut) { song.playback.seek(to: $0) }
        }
        ToolbarItem(placement: .primaryAction) {
            CutToolbar(project: project, cut: cut)
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Drehbuch", systemImage: "list.bullet.rectangle") { cut.showsDrehbuch = true }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(project.analysis == nil)
                .help("Kapitel und Drehbuch: welche Kapitel in welchem Songabschnitt (⇧⌘D)")
                .accessibilityIdentifier("toolbar.drehbuch")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Exportieren …", systemImage: "square.and.arrow.up") { cut.showsExport = true }
                .disabled(project.cut == nil)
                .help("Timeline für Final Cut Pro, DaVinci Resolve oder Premiere exportieren (⌘E)")
                .accessibilityIdentifier("toolbar.export")
        }
        ToolbarItem(placement: .primaryAction) {
            JobCenterButton()
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation { showsInspector.toggle() }
            } label: {
                Label("Inspektor", systemImage: "sidebar.right")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help("Inspektor ein- oder ausblenden (⌥⌘I)")
        }
    }

    private func removeSelectedClip() {
        guard let id = selectedClipID else { return }
        errorMessage = document.run(RemoveClips(clipIDs: [id]), undoManager: undoManager)
        if errorMessage == nil { selectedClipIDs = [] }
    }

    private func createLegacyBackupIfNeeded() {
        guard document.migratedFrom != nil, let url = configuration?.fileURL else { return }
        do {
            if let backup = try LegacyBackup.ensureBackup(of: url) {
                backupNotice =
                    "Aus SyllaBeat 0.2 übernommen. Das Original bleibt als „\(backup.lastPathComponent)“ erhalten; gesichert wird im neuen Format."
            }
        } catch {
            errorMessage =
                "Die Sicherungskopie im alten Format konnte nicht angelegt werden: \(error.localizedDescription)"
        }
    }
}

struct Banner: View {
    var text: String
    var systemImage: String
    var identifier: String
    var actionTitle: String?
    var action: (() -> Void)?
    var close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(.tint)
            Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.small)
            }
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Hinweis schließen")
                .accessibilityLabel("Hinweis schließen")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// Liefert das Fenster einer SwiftUI-Ansicht (für die Verbindung zum NSDocument).
struct WindowAccessor: NSViewRepresentable {
    var found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { found(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

extension FocusedValues {
    @Entry var projectMedia: MediaController?
    @Entry var projectCut: CutController?
}
