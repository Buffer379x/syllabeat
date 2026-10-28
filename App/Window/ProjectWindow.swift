import SwiftUI
import SyllaBeatCore

/// Ein Dokumentfenster: Bibliothek, Vorschau, Inspektor und darunter die Timeline über die volle Breite.
struct ProjectWindow: View {
    @ObservedObject var document: ProjectDocument
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
                Banner(text: backupNotice, systemImage: "clock.arrow.circlepath") { self.backupNotice = nil }
            }
            VSplitView {
                HSplitView {
                    LibraryPane(clips: project.clips, selection: $selectedClipID)
                        .frame(minWidth: 220, idealWidth: 270, maxWidth: 460)
                    PreviewPane(project: project)
                        .frame(minWidth: 380, maxWidth: .infinity)
                    if showsInspector {
                        InspectorPane(document: document, selectedClipID: selectedClipID, errorMessage: $errorMessage)
                            .frame(minWidth: 250, idealWidth: 290, maxWidth: 460)
                    }
                }
                .frame(minHeight: 320, maxHeight: .infinity)
                TimelinePane(project: project)
                    .frame(minHeight: 172, idealHeight: 176, maxHeight: 200)
            }
        }
        .toolbar { toolbar }
        .navigationSubtitle(subtitle)
        .task(id: configuration?.fileURL) { createLegacyBackupIfNeeded() }
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
        .accessibilityIdentifier("migrationBanner")
    }
}
