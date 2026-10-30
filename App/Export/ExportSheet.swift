import AppKit
import SwiftUI
import SyllaBeatCore
import SyllaBeatMedia
import SyllaBeatUI

/// Export-Dialog: Zuerst das Zielprogramm, die Formate ergeben sich daraus („Erweitert“ zeigt alle). Vor dem
/// Schreiben werden fehlende Medien gemeldet; geschrieben wird atomar.
struct ExportSheet: View {
    var project: Project
    var close: () -> Void
    @AppStorage("export.target") private var targetRaw = ExportTarget.finalCut.rawValue
    @AppStorage("export.sectionMarkers") private var sectionMarkers = true
    @AppStorage("export.lineMarkers") private var lineMarkers = true
    @AppStorage("export.barMarkers") private var barMarkers = false
    @AppStorage("export.keywords") private var keywords = true
    @AppStorage("export.songPrimary") private var songPrimary = false
    @AppStorage("export.folder") private var folderPath = ""
    @State private var advanced = false
    @State private var selected: Set<ExportFormat> = []
    @State private var written: [URL] = []
    @State private var problem: String?
    @State private var confirmReplace: [String] = []
    @AppStorage("export.codec") private var codecRaw = RenderSettings.Codec.h264.rawValue
    @AppStorage("export.thumbnail") private var thumbnail = true
    @State private var renderProgress: Double?
    @State private var renderTask: Task<Void, Never>?

    private var target: ExportTarget { ExportTarget(rawValue: targetRaw) ?? .finalCut }

    private var formats: [ExportFormat] {
        advanced ? ExportFormat.allCases.filter(selected.contains) : target.formats
    }

    private var options: ExportOptions {
        ExportOptions(
            sectionMarkers: sectionMarkers, lineMarkers: lineMarkers, barMarkers: barMarkers, keywords: keywords,
            songPlacement: songPrimary ? .primary : .connected)
    }

    private var folder: URL {
        folderPath.isEmpty
            ? URL.documentsDirectory.appendingPathComponent("SyllaBeat Exporte", isDirectory: true)
            : URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    private var baseName: String { project.name.replacingOccurrences(of: "/", with: "-") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Zielprogramm", selection: $targetRaw) {
                    ForEach(ExportTarget.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("export.target")
                if advanced {
                    Section("Formate") {
                        ForEach(ExportFormat.allCases) { format in
                            Toggle(
                                format.title,
                                isOn: Binding(
                                    get: { selected.contains(format) },
                                    set: { on in if on { selected.insert(format) } else { selected.remove(format) } }))
                        }
                    }
                } else {
                    LabeledContent("Dateien") {
                        Text(fileNames.joined(separator: "\n"))
                            .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
                if target == .video {
                    Section("Video") {
                        LabeledContent(
                            "Format",
                            value:
                                "\(project.timeline.width)×\(project.timeline.height) · \(Format.fps(project.timeline.fps)) fps"
                        )
                        Picker("Codec", selection: $codecRaw) {
                            ForEach(RenderSettings.Codec.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        }
                        Toggle("Vorschaubild (1280×720)", isOn: $thumbnail)
                        Label(
                            "Für KI-generierte Inhalte in YouTube Studio prüfen, ob eine Kennzeichnung nötig ist.",
                            systemImage: "info.circle"
                        )
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let renderProgress {
                            ProgressView("Video wird gerendert …", value: renderProgress)
                                .accessibilityIdentifier("export.renderProgress")
                        }
                    }
                }
                if target != .video {
                    Section("Marker und Metadaten") {
                        Toggle("Abschnitte als Marker", isOn: $sectionMarkers)
                        Toggle("Textzeilen als Marker", isOn: $lineMarkers)
                        Toggle("Jeden Takt als Marker", isOn: $barMarkers)
                        Toggle("Schlagwörter und Beschreibungen", isOn: $keywords)
                        if target == .finalCut || formats.contains(.fcpxml) {
                            Picker("Song in Final Cut Pro", selection: $songPrimary) {
                                Text(ExportOptions.SongPlacement.connected.title).tag(false)
                                Text(ExportOptions.SongPlacement.primary.title).tag(true)
                            }
                            .help(
                                "Verbunden: wie 0.2.0, der Song hängt am ersten Clip. Primärhandlung: Der Song liegt unten, die Clips darüber."
                            )
                        }
                    }
                }
                LabeledContent("Ordner") {
                    HStack {
                        Text(folder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Wählen …", action: chooseFolder)
                    }
                }
                Toggle("Erweitert (alle Formate)", isOn: $advanced)
                    .onChange(of: advanced) { _, on in if on, selected.isEmpty { selected = Set(target.formats) } }
            }
            .formStyle(.grouped)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .padding(.horizontal, 20).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("export.problem")
            }
            if !written.isEmpty {
                Label("\(written.count) Dateien geschrieben.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green).padding(.horizontal, 20)
                    .accessibilityIdentifier("export.done")
            }
            HStack {
                if !written.isEmpty {
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting(written) }
                    if let fcpxml = written.first(where: { $0.pathExtension == "fcpxml" }) {
                        Button("In Final Cut Pro öffnen") { openInFinalCut(fcpxml) }
                            .disabled(Self.finalCut == nil)
                            .help(
                                Self.finalCut == nil
                                    ? "Final Cut Pro ist nicht installiert."
                                    : "Importiert die Timeline in Final Cut Pro"
                            )
                            .accessibilityIdentifier("export.openFinalCut")
                    }
                }
                Spacer()
                Button(renderProgress == nil ? "Schließen" : "Abbrechen", role: .cancel) {
                    if renderTask != nil {
                        renderTask?.cancel()
                    } else {
                        close()
                    }
                }
                .keyboardShortcut(.cancelAction)
                Button(target == .video ? "Rendern" : "Exportieren", action: requestExport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(formats.isEmpty || project.cut == nil || renderTask != nil)
                    .accessibilityIdentifier("export.run")
            }
            .padding(20)
        }
        .frame(width: 560)
        .alert(
            "Dateien ersetzen?",
            isPresented: Binding(get: { !confirmReplace.isEmpty }, set: { if !$0 { confirmReplace = [] } })
        ) {
            Button("Ersetzen", role: .destructive) {
                confirmReplace = []
                runExport()
            }
            Button("Abbrechen", role: .cancel) { confirmReplace = [] }
        } message: {
            Text(confirmReplace.joined(separator: "\n"))
        }
    }

    static var finalCut: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FinalCut")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Als Exportordner wählen"
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
    }

    /// Dateinamen der Auswahl; beim Video kommen MP4 und Vorschaubild dazu.
    private var fileNames: [String] {
        var names = formats.map { $0.fileName(base: baseName) }
        if target == .video, !advanced {
            names.insert("\(baseName).mp4", at: 0)
            if thumbnail { names.append("vorschaubild.jpg") }
        }
        return names
    }

    private func requestExport() {
        let existing = fileNames.filter {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        if existing.isEmpty { runExport() } else { confirmReplace = existing }
    }

    private func runExport() {
        problem = nil
        written = []
        do {
            written = try ProjectExporter.export(
                project, formats: formats, options: options, to: folder, baseName: baseName)
        } catch {
            problem = error.localizedDescription
            return
        }
        if target == .video, !advanced { render() }
    }

    /// MP4 aus derselben Frame-Tabelle wie Vorschau und Exporte, danach das Vorschaubild.
    private func render() {
        guard let cut = project.cut else { return }
        let table: FrameTable
        do {
            table = try CutCompiler.compile(project, cut: cut)
        } catch {
            problem = error.localizedDescription
            return
        }
        let paths = Dictionary(project.clips.map { ($0.id, $0.media.path) }, uniquingKeysWith: { first, _ in first })
        let target = folder.appendingPathComponent("\(baseName).mp4")
        let settings = RenderSettings(codec: RenderSettings.Codec(rawValue: codecRaw) ?? .h264)
        let still = thumbnail ? YouTubeExport.thumbnailScene(project, cut: cut) : nil
        let project = project
        renderProgress = 0
        renderTask = Task {
            defer {
                renderTask = nil
                renderProgress = nil
            }
            do {
                try await VideoRenderer.render(
                    table: table, paths: paths, song: project.song?.path, fit: project.timeline.fit, settings: settings,
                    to: target
                ) { value in Task { @MainActor in renderProgress = value } }
                written.insert(target, at: 0)
                if let still, let clip = project.clip(withID: still.clipID),
                    let scene = clip.scenes.first(where: { $0.id == still.sceneID })
                {
                    let image = folder.appendingPathComponent("vorschaubild.jpg")
                    try await VideoRenderer.writeStill(
                        clipPath: clip.media.path, at: scene.keyframeTime ?? (scene.start + scene.end) / 2,
                        size: CGSize(width: 1280, height: 720), to: image)
                    written.append(image)
                }
            } catch is CancellationError {
                problem = "Rendern abgebrochen."
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func openInFinalCut(_ file: URL) {
        guard let app = Self.finalCut else { return }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) {
            _, error in
            if let error { Task { @MainActor in problem = "Final Cut Pro: \(error.localizedDescription)" } }
        }
    }
}
