import AppKit
import SwiftUI
import SyllaBeatCore

@main
struct SyllaBeatApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var services = AppServices()

    var body: some Scene {
        DocumentGroup(newDocument: { ProjectDocument() }) { file in
            ProjectWindow(document: file.document)
                .environment(services)
        }
        .defaultSize(width: 1280, height: 820)

        Settings {
            SettingsView()
                .environment(services)
        }
    }
}

/// Öffnet beim Start ein Projekt aus `-SBOpenDocument <Pfad>` (für UI-Tests und `sbtool`-Abläufe).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var documentToOpen: URL? {
        UserDefaults.standard.string(forKey: "SBOpenDocument").map { URL(fileURLWithPath: $0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("SyllaBeat \(BuildInfo.version, privacy: .public) gestartet")
        guard let url = documentToOpen else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error {
                Log.document.error("Öffnen fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        documentToOpen == nil
    }
}
