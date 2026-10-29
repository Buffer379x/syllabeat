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

    var body: some View {
        if let media, let song {
            ProjectWorkspace(document: document, media: media, song: song)
        } else {
            Color.clear.onAppear {
                media = MediaController(document: document, services: services)
                song = SongController(document: document, services: services)
            }
        }
    }
}

/// Bibliothek, Vorschau, Inspektor und darunter die Timeline über die volle Breite.
struct ProjectWorkspace: View {
    @ObservedObject var document: ProjectDocument
    var media: MediaController
    var song: SongController
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
            VSplitView {
                HSplitView {
                    LibraryPane(project: project, media: media, selection: $selectedClipID)
                        .frame(minWidth: 220, idealWidth: 270, maxWidth: 460)
                    PreviewPane(project: project, playback: song.playback)
                        .frame(minWidth: 380, maxWidth: .infinity)
                    if showsInspector {
                        InspectorPane(
                            document: document, media: media, song: song, selectedClipID: selectedClipID,
                            errorMessage: $errorMessage
                        )
                        .frame(minWidth: 250, idealWidth: 290, maxWidth: 460)
                    }
                }
                .frame(minHeight: 320, maxHeight: .infinity)
                TimelinePane(project: project, song: song) { command in
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
        .onDeleteCommand(perform: removeSelectedClip)
        .toolbar { toolbar }
        .navigationSubtitle(subtitle)
        .task(id: configuration?.fileURL) { createLegacyBackupIfNeeded() }
        .task {
            media.undoManager = undoManager
            media.start()
            song.songChanged()
            // Automatisierung (UI-Tests): `-SBImportPaths "<Pfad>|<Pfad>"` importiert beim Öffnen.
            if let paths = UserDefaults.standard.string(forKey: "SBImportPaths") {
                media.importItems(paths.split(separator: "|").map { URL(fileURLWithPath: String($0)) })
            }
        }
        .onChange(of: undoManager) { _, manager in media.undoManager = manager }
        .onChange(of: project.song) { _, _ in song.songChanged() }
        .alert(
            "Aktion nicht möglich", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
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
    var close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(.tint)
            Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
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
}
