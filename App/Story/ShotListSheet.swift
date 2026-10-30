import AppKit
import SwiftUI
import SyllaBeatAI
import SyllaBeatCore
import UniformTypeIdentifiers

/// „Was fehlt?“: Zeilen ohne klares Bild, Kapitel mit zu wenig Material und Motive nur mit Wasserzeichen – jeweils mit
/// Dateinamen und Prompt für den KI-Generator.
struct ShotListSheet: View {
    var project: Project
    var textScores: TextScores
    var run: (any EditCommand) -> Void
    var close: () -> Void
    @State private var style = ""

    private var entries: [ShotListEntry] {
        var confidence: [String: Double] = [:]
        for line in project.analysis?.lines ?? [] {
            if let row = textScores.values[line.id] {
                confidence[line.text.trimmingCharacters(in: .whitespacesAndNewlines)] = CutEngine.gateConfidence(row)
            }
        }
        return ShotList.entries(CoverageAnalyzer.analyze(project, lineConfidence: confidence), project: project)
    }

    var body: some View {
        let entries = entries
        VStack(alignment: .leading, spacing: 12) {
            Text("Was fehlt?").font(.title3.weight(.semibold))
            TextField(
                "Stil-Vorlage", text: $style,
                prompt: Text("z. B. Strickpuppen aus Wolle, Stop-Motion-Look, sonniger Bauernhof, 16:9")
            )
            .onSubmit { run(SetPromptStyle(text: style)) }
            .onAppear { style = project.story.promptStyle }
            .accessibilityIdentifier("shotlist.style")
            if entries.isEmpty {
                Text("Nichts Auffälliges: Zeilen, Kapitel und Motive sind versorgt.").foregroundStyle(.secondary)
            }
            List(Array(entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 3) {
                    Label(entry.reason, systemImage: icon(entry.kind)).font(.callout.weight(.semibold))
                    Text("Datei: \(entry.fileName)").font(.caption.monospaced()).textSelection(.enabled)
                    HStack(alignment: .top) {
                        Text(entry.prompt).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer()
                        Button("Kopieren", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.prompt, forType: .string)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 260)
            .accessibilityIdentifier("shotlist.entries")
            HStack {
                Text("Neue Clips in die Bibliothek ziehen; das Kapitel wird vorgeschlagen.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Als Text sichern …") { save(entries) }.accessibilityIdentifier("shotlist.save")
                Button("Fertig") {
                    if style != project.story.promptStyle { run(SetPromptStyle(text: style)) }
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 440)
        .accessibilityIdentifier("shotlist")
    }

    private func icon(_ kind: ShotListEntry.Kind) -> String {
        switch kind {
        case .line: "text.quote"
        case .chapter: "book"
        case .watermark: "drop.halffull"
        }
    }

    private func save(_ entries: [ShotListEntry]) {
        let text = ShotList.text(entries)
        // Automatisierung (UI-Tests): `-shotlist.folder <Pfad>` sichert ohne Dialog.
        if let folder = UserDefaults.standard.string(forKey: "shotlist.folder") {
            try? text.write(
                to: URL(fileURLWithPath: folder).appendingPathComponent("drehliste.txt"), atomically: true,
                encoding: .utf8)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Drehliste.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
