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
    @State private var selectedClipID: String?
    @State private var showsInspector = true
    @State private var backupNotice: String?
    @State private var errorMessage: String?

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
                    LibraryPane(project: project, media: media, selection: $selectedClipID)
                        .frame(minWidth: 220, idealWidth: 270, maxWidth: 460)
                    PreviewPane(project: project, playback: song.playback, cut: cut)
                        .frame(minWidth: 380, maxWidth: .infinity)
                    if showsInspector {
                        InspectorPane(
                            document: document, media: media, song: song, cut: cut, ai: ai,
                            selectedClipID: selectedClipID,
                            errorMessage: $errorMessage
                        )
                        .frame(minWidth: 250, idealWidth: 290, maxWidth: 460)
                    }
                }
                .frame(minHeight: 320, maxHeight: .infinity)
                TimelinePane(project: project, song: song, cut: cut) { command in
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
        .sheet(isPresented: Bindable(cut).showsExport) {
            ExportSheet(project: project) { cut.showsExport = false }
        }
        .sheet(item: Bindable(ai).manualExchange) { exchange in
            ManualExchangeSheet(exchange: exchange, ai: ai)
        }
        .onChange(of: previewSignal, initial: true) { _, _ in cut.updatePreview() }
        .task(id: textSignal) { await cut.refreshTextScores() }
        // Clip oder Einstellung: Der Inspektor zeigt immer nur eines davon.
        .onChange(of: selectedClipID) { _, id in if id != nil { cut.selection = [] } }
        .onChange(of: cut.selection) { _, ids in if !ids.isEmpty { selectedClipID = nil } }
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

    private var subtitle: String {
        let fps = Format.fps(project.timeline.fps)
        return "\(project.timeline.width)×\(project.timeline.height) · \(fps) fps"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            StatusChips(project: project)
        }
        ToolbarItem(placement: .primaryAction) {
            CutToolbar(project: project, cut: cut)
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
        if errorMessage == nil { selectedClipID = nil }
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
