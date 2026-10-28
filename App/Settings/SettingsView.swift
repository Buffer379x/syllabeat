import AppKit
import SwiftUI
import SyllaBeatAI
import SyllaBeatCore

/// Einstellungsfenster mit den fünf Bereichen aus F-17. Inhalte kommen mit den jeweiligen Meilensteinen dazu.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("Allgemein", systemImage: "gearshape") }
            PlannedSettings(
                title: "Modelle", systemImage: "cpu",
                detail:
                    "Hier stehen bald alle Modelle pro Aufgabe, mit Größe, RAM-Bedarf, Lizenz und der Empfehlung für diesen Mac."
            )
            .tabItem { Label("Modelle", systemImage: "cpu") }
            PlannedSettings(
                title: "Anbieter", systemImage: "network",
                detail:
                    "Lokal (MLX, Apple Foundation Models), Ollama, LM Studio und Cloud-Anbieter mit Schlüssel im Schlüsselbund."
            )
            .tabItem { Label("Anbieter", systemImage: "network") }
            PlannedSettings(
                title: "Export", systemImage: "square.and.arrow.up",
                detail: "Standardziel (Final Cut Pro, DaVinci Resolve, Premiere), Marker und Schlagwörter."
            )
            .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            PlannedSettings(
                title: "Datenschutz", systemImage: "hand.raised",
                detail: "Was an Cloud-Anbieter gesendet werden darf. Videos verlassen den Mac nie."
            )
            .tabItem { Label("Datenschutz", systemImage: "hand.raised") }
        }
        .frame(width: 560, height: 420)
    }
}

private struct GeneralSettings: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        Form {
            LabeledContent("Version", value: "\(BuildInfo.version) (\(BuildInfo.build))")
            Section("Speicherorte") {
                FolderRow(title: "Modelle", url: Locations.models)
                FolderRow(title: "Zwischenspeicher", url: Locations.caches)
            }
            Section("Diagnose") {
                LabeledContent("Inferenzdienst") {
                    HStack {
                        InferenceStatusText(check: services.inferenceCheck)
                        Button("Prüfen") { services.checkInference() }
                            .disabled(services.inferenceCheck == .checking)
                            .accessibilityIdentifier("settings.checkInference")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct InferenceStatusText: View {
    var check: AppServices.InferenceCheck

    var body: some View {
        switch check {
        case .unknown: Text("nicht geprüft").foregroundStyle(.secondary)
        case .checking: ProgressView().controlSize(.small)
        case .available(let status):
            Label(
                "bereit · PID \(status.processID) · \(Format.bytes(status.residentMemoryBytes))",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.tint)
            .accessibilityIdentifier("settings.inferenceReady")
        case .failed(let reason): Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}

private struct FolderRow: View {
    var title: String
    var url: URL

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(url.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button("Im Finder zeigen") {
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }
}

private struct PlannedSettings: View {
    var title: String
    var systemImage: String
    var detail: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        }
    }
}

/// Speicherorte aus Abschnitt 5.5 des Plans.
enum Locations {
    static var applicationSupport: URL {
        URL.applicationSupportDirectory.appendingPathComponent("SyllaBeat", isDirectory: true)
    }

    static var models: URL { applicationSupport.appendingPathComponent("Models", isDirectory: true) }
    static var caches: URL { URL.cachesDirectory.appendingPathComponent("SyllaBeat", isDirectory: true) }
}
