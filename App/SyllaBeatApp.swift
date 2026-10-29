import AppKit
import SwiftUI
import SyllaBeatAI
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
        .commands {
            MediaCommands()
            CutCommands()
            HelpCommands()
        }

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

    /// `--self-test`: eingebaute Prüfungen plus Bündel (Inferenzdienst, Hilfe), Ausgabe auf stdout, dann Ende.
    private var selfTest: Bool { CommandLine.arguments.contains("--self-test") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("SyllaBeat \(BuildInfo.version, privacy: .public) gestartet")
        if selfTest {
            Task { await Self.runSelfTest() }
            return
        }
        guard let url = documentToOpen else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error {
                Log.document.error("Öffnen fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        documentToOpen == nil && !selfTest
    }

    @MainActor
    static func runSelfTest() async {
        var result = SelfTest.run()
        if Bundle.main.url(forResource: "BEDIENUNG", withExtension: "html") != nil {
            result.passed.append("Hilfe im Bündel")
        } else {
            result.failed.append("Hilfe im Bündel")
        }
        do {
            let status = try await InferenceClient().status()
            result.passed.append("Inferenzdienst antwortet (\(status.version))")
        } catch {
            result.failed.append("Inferenzdienst: \(error.localizedDescription)")
        }
        var output = "SyllaBeat \(BuildInfo.version) (\(BuildInfo.build)) – Selbsttest\n"
        for name in result.passed { output += "✓ \(name)\n" }
        for name in result.failed { output += "✗ \(name)\n" }
        output += result.ok ? "Bestanden (\(result.passed.count) Prüfungen).\n" : "Fehlgeschlagen.\n"
        FileHandle.standardOutput.write(Data(output.utf8))
        exit(result.ok ? 0 : 1)
    }
}

/// Hilfe: die Bedienungsanleitung aus dem App-Bündel im Browser.
struct HelpCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("SyllaBeat-Hilfe") {
                if let url = Bundle.main.url(forResource: "BEDIENUNG", withExtension: "html") {
                    NSWorkspace.shared.open(url)
                }
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}

/// Menüeinträge für das aktive Projektfenster.
/// Menü „Schnitt“: wirkt auf das aktive Dokumentfenster.
struct CutCommands: Commands {
    @FocusedValue(\.projectCut) private var cut

    var body: some Commands {
        CommandMenu("Schnitt") {
            Button("Neu würfeln") { cut?.reroll() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!(cut?.canCut ?? false))
            Button("Auswahl neu schneiden") { cut?.recutSelection() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(cut?.selection.isEmpty ?? true)
            Button("Fixieren / lösen") { cut?.toggleLockSelection() }
                .keyboardShortcut("l", modifiers: [])
                .disabled(cut?.selection.isEmpty ?? true)
            Divider()
            Button("Drei Varianten erzeugen") { cut?.createVariants() }
                .disabled(!(cut?.canCut ?? false))
            Divider()
            Button("Exportieren …") { cut?.showsExport = true }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(cut == nil)
        }
    }
}

struct MediaCommands: Commands {
    @FocusedValue(\.projectMedia) private var media

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Section {
                Button("Clips oder Song hinzufügen …") { media?.presentImportPanel() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(media == nil)
                Button("Medien neu verknüpfen …") { media?.presentRelinkPanel() }
                    .disabled(media == nil)
            }
        }
    }
}
