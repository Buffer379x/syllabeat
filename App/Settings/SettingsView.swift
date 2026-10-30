import AppKit
import SwiftUI
import SyllaBeatAI
import SyllaBeatCore
import SyllaBeatMedia
import SyllaBeatUI

/// Einstellungsfenster mit den fünf Bereichen aus F-17. Inhalte kommen mit den jeweiligen Meilensteinen dazu.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("Allgemein", systemImage: "gearshape") }
            ModelSettings().tabItem { Label("Modelle", systemImage: "cpu") }
            ProviderSettings().tabItem { Label("Anbieter", systemImage: "network") }
            PlannedSettings(
                title: "Export", systemImage: "square.and.arrow.up",
                detail: "Standardziel (Final Cut Pro, DaVinci Resolve, Premiere), Marker und Schlagwörter."
            )
            .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            PrivacySettings().tabItem { Label("Datenschutz", systemImage: "hand.raised") }
        }
        .frame(width: 600, height: 520)
    }
}

private struct GeneralSettings: View {
    @Environment(AppServices.self) private var services
    @AppStorage("importSubfolders") private var importSubfolders = true
    @AppStorage("clipKnowledge") private var clipKnowledge = true
    @State private var knowledgeRemoved: Int?
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
            Section("Clip-Wissen") {
                Toggle("Sperrbereiche, Bewertung und Tageszeit projektübergreifend merken", isOn: $clipKnowledge)
                    .help("Dieselbe Datei in einem anderen Projekt übernimmt, was du hier festgelegt hast.")
                HStack {
                    Button("Gemerktes Clip-Wissen löschen") { knowledgeRemoved = Self.removeKnowledge() }
                    if let knowledgeRemoved {
                        Text("\(knowledgeRemoved) Einträge gelöscht").foregroundStyle(.secondary)
                    }
                }
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

/// Modelle je Aufgabe mit Größe, Speicherbedarf, Lizenz und der Empfehlung für diesen Mac (F-15).
private struct ModelSettings: View {
    @Environment(AppServices.self) private var services
    @AppStorage("transcriptionLanguage") private var language = "de"
    @AppStorage("autoTranscribe") private var autoTranscribe = true

    var body: some View {
        let _ = services.installGeneration
        Form {
            Section("Gesangserkennung") {
                LabeledContent {
                    if services.installing.contains("whisper") {
                        ProgressView().controlSize(.small)
                    } else if TranscriptionModel.isInstalled {
                        Button("Löschen", role: .destructive) { services.uninstallTranscription() }
                    } else {
                        Button("Laden (\(Format.bytes(UInt64(TranscriptionModel.downloadBytes))))") {
                            services.installTranscription()
                        }
                    }
                } label: {
                    Text(TranscriptionModel.title)
                    Text(
                        "MIT · \(TranscriptionModel.isInstalled ? "geladen" : "nicht geladen") · läuft lokal, Wörter mit Zeiten"
                    )
                }
                Picker("Sprache", selection: $language) {
                    Text("Automatisch").tag("")
                    Text("Deutsch").tag("de")
                    Text("Englisch").tag("en")
                }
                Toggle("Nach der Songanalyse automatisch erkennen", isOn: $autoTranscribe)
            }
            Section("Bildsuche") {
                ForEach(ModelCatalog.all.filter { $0.task == .embedding }) { package in
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
                LabeledContent {
                    Text(AppleIntelligenceProvider.availability.reason).foregroundStyle(.secondary)
                } label: {
                    Text("Apple Intelligence")
                    Text("eingebaut, kein Download · Text, Bilder ab macOS 27")
                }
                ForEach([ModelCatalog.qwen3VL8bit, ModelCatalog.qwen3VL4bit]) { package in
                    PackageRow(package: package, recommended: package == ModelCatalog.recommendedVision())
                }
            } header: {
                Text("Bildbeschreibung und Regie")
            } footer: {
                Text(
                    "Dieser Mac hat \(Format.bytes(ModelCatalog.physicalMemory)) Arbeitsspeicher. Lokale Modelle laufen im Inferenzdienst und werden nach zwei Minuten Ruhe entladen."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            LegacyModelsSection()
            Section {
                FolderRow(title: "Ort", url: Locations.models)
                LabeledContent("Speicherort") {
                    HStack {
                        Button("Ändern …", action: chooseFolder)
                        if UserDefaults.standard.string(forKey: "modelsFolder") != nil {
                            Button("Standard") {
                                UserDefaults.standard.removeObject(forKey: "modelsFolder")
                                services.refreshModels()
                            }
                        }
                    }
                }
            } footer: {
                Text("Bereits geladene Modelle bleiben am alten Ort und werden dort nicht mehr gefunden.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Als Modellordner wählen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "modelsFolder")
        services.refreshModels()
    }
}

/// Ein ladbares Modell mit Größe, Speicherbedarf, Status und „Empfohlen für deinen Mac“.
private struct PackageRow: View {
    var package: ModelPackage
    var recommended: Bool
    @Environment(AppServices.self) private var services

    var body: some View {
        let _ = services.installGeneration
        LabeledContent {
            if services.installing.contains(package.id) {
                ProgressView().controlSize(.small)
            } else if package.isInstalled {
                Button("Löschen", role: .destructive) { services.uninstall(package) }
            } else {
                Button("Laden (\(Format.bytes(UInt64(package.downloadBytes))))") { services.install(package) }
                    .accessibilityIdentifier("model.install.\(package.id)")
            }
        } label: {
            HStack(spacing: 6) {
                Text(package.title)
                if ModelCatalog.tooLarge(package) {
                    Label("Zu groß für diesen Mac", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                        .accessibilityIdentifier("model.tooLarge.\(package.id)")
                } else if recommended {
                    Text("Empfohlen für deinen Mac").font(.caption2.weight(.semibold))
                        .accessibilityIdentifier("model.recommended.\(package.id)")
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.tint.opacity(0.2), in: Capsule())
                }
            }
            Text(
                "\(package.license) · \(package.isInstalled ? "geladen" : "nicht geladen") · bis \(Format.bytes(UInt64(package.memoryBytes))) Arbeitsspeicher · läuft lokal"
            )
        }
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

/// Modelle aus SyllaBeat 0.2 (Ollama, Whisper über Hugging Face) braucht 0.3 nicht mehr: Hinweis mit Größe,
/// „Im Finder zeigen“ und Löschen nach Rückfrage.
private struct LegacyModelsSection: View {
    @State private var folders: [(url: URL, bytes: Int64)] = []
    @State private var confirm: URL?

    static var candidates: [URL] {
        let base = URL.applicationSupportDirectory.appendingPathComponent("SyllaBeat/models", isDirectory: true)
        return ["ollama", "huggingface"].map { base.appendingPathComponent($0, isDirectory: true) }
    }

    var body: some View {
        if !folders.isEmpty {
            Section {
                ForEach(folders, id: \.url) { folder in
                    LabeledContent {
                        HStack {
                            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
                            Button("Löschen …", role: .destructive) { confirm = folder.url }
                        }
                    } label: {
                        Text(folder.url.lastPathComponent == "ollama" ? "Ollama-Modelle" : "Whisper-Modelle (Python)")
                        Text(
                            "\(Format.bytes(UInt64(max(0, folder.bytes)))) · von SyllaBeat 0.2, in 0.3 nicht mehr genutzt"
                        )
                    }
                }
            } header: {
                Text("Aus SyllaBeat 0.2")
            } footer: {
                Text(
                    "0.3 nutzt eigene Modelle (Apple Intelligence, MLX, Core ML). Die alten Dateien können weg, solange 0.2 nicht mehr gebraucht wird."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .confirmationDialog(
                "„\(confirm?.lastPathComponent ?? "")“ endgültig löschen?",
                isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })
            ) {
                Button("Löschen", role: .destructive) {
                    if let url = confirm { try? FileManager.default.removeItem(at: url) }
                    confirm = nil
                    refresh()
                }
            } message: {
                Text("SyllaBeat 0.2 müsste die Modelle danach neu laden.")
            }
        }
        Color.clear.frame(height: 0).onAppear(perform: refresh)
    }

    private func refresh() {
        folders = Self.candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { ($0, FileManager.default.allocatedSize(of: $0)) }
    }
}

extension GeneralSettings {
    /// Löscht alle `knowledge.json` im Zwischenspeicher; Rückgabe: Anzahl.
    static func removeKnowledge() -> Int {
        let cache = MediaCache()
        let folders =
            (try? FileManager.default.contentsOfDirectory(at: cache.root, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for folder in folders {
            let file = folder.appendingPathComponent("knowledge.json")
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }
}
