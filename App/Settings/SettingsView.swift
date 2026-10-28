import AppKit
import SwiftUI
import SyllaBeatAI
import SyllaBeatCore
import SyllaBeatMedia

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
    @AppStorage("importSubfolders") private var importSubfolders = true
    @AppStorage("workingCopyPreset") private var workingCopyPreset = FFmpeg.Preset.proResLT.rawValue

    var body: some View {
        @Bindable var services = services
        Form {
            LabeledContent("Version", value: "\(BuildInfo.version) (\(BuildInfo.build))")
            Section("Import") {
                Toggle("Unterordner einbeziehen", isOn: $importSubfolders)
                Picker("Arbeitskopien als", selection: $workingCopyPreset) {
                    ForEach(FFmpeg.Preset.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                ComponentRow(services: services)
            }
            Section("Zwischenspeicher") {
                LabeledContent("Belegt") {
                    HStack {
                        Text(services.cacheBytes.map { Format.bytes(UInt64(max(0, $0))) } ?? "…")
                            .foregroundStyle(.secondary)
                        Button("Leeren") { services.clearCache() }
                            .help("Vorschaubilder, Filmstreifen und Embeddings werden bei Bedarf neu erzeugt.")
                    }
                }
                Picker("Höchstens", selection: $services.cacheLimitGB) {
                    ForEach([2, 5, 10, 20, 50], id: \.self) { Text("\($0) GB").tag($0) }
                }
                FolderRow(title: "Ort", url: Locations.caches)
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
        .onAppear { services.trimCache() }
    }
}

/// ffmpeg als nachladbare Komponente (F-20).
private struct ComponentRow: View {
    var services: AppServices

    var body: some View {
        let _ = services.installGeneration
        LabeledContent {
            if services.installing.contains("ffmpeg") {
                ProgressView().controlSize(.small)
            } else if FFmpeg.isInstalled {
                Button("Entfernen") { services.uninstallFFmpeg() }
            } else {
                Button("Laden (28 MB)") { services.installFFmpeg() }
            }
        } label: {
            Text("ffmpeg")
            Text(
                FFmpeg.isInstalled
                    ? "Installiert. Für MKV, AVI, WebM, MTS und CFR-Arbeitskopien."
                    : "Nur nötig für MKV, AVI, WebM, MTS und Clips mit variabler Bildrate.")
        }
    }
}

/// Modelle je Aufgabe. Volle Verwaltung (RAM-Empfehlung, Speicherort) folgt mit M5.
private struct ModelSettings: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let _ = services.installGeneration
        Form {
            Section("Bildsuche") {
                ForEach(ModelCatalog.all) { package in
                    LabeledContent {
                        if services.installing.contains(package.id) {
                            ProgressView().controlSize(.small)
                        } else if package.isInstalled {
                            Button("Löschen", role: .destructive) { services.uninstall(package) }
                        } else {
                            Button("Laden (\(Format.bytes(UInt64(package.downloadBytes))))") {
                                services.install(package)
                            }
                            .accessibilityIdentifier("model.install.\(package.id)")
                        }
                    } label: {
                        Text(package.title)
                        Text("\(package.license) · \(package.isInstalled ? "geladen" : "nicht geladen") · läuft lokal")
                    }
                }
            }
            Section {
                FolderRow(title: "Ort", url: Locations.models)
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
