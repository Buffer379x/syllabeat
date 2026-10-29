import AppKit
import SwiftUI
import SyllaBeatCore
import SyllaBeatUI

/// Inspektor: zeigt die ausgewählte Einstellung, den ausgewählten Clip oder, ohne Auswahl, das Projekt.
struct InspectorPane: View {
    @ObservedObject var document: ProjectDocument
    var media: MediaController
    var song: SongController
    var cut: CutController
    var selectedClipID: String?
    @Binding var errorMessage: String?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let shot = cut.selectedShot {
                    ShotInspector(shot: shot, project: document.project, media: media, cut: cut)
                } else if let id = selectedClipID, let clip = document.project.clip(withID: id) {
                    ClipInspector(clip: clip, project: document.project, media: media) { command in
                        errorMessage = document.run(command, undoManager: undoManager)
                    }
                } else {
                    ProjectInspector(document: document, song: song, errorMessage: $errorMessage)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Neue Auswahl beginnt oben statt an der alten Scrollposition.
        .id(cut.selectedShot?.id ?? selectedClipID ?? "projekt")
        .background(.background)
        .accessibilityIdentifier("inspector")
    }
}

private struct ClipInspector: View {
    var clip: Clip
    var project: Project
    var media: MediaController
    var run: (any EditCommand) -> Void
    @State private var description = ""
    @State private var tags = ""
    @FocusState private var focus: Field?

    enum Field { case description, tags }

    var body: some View {
        SkimmingThumbnail(clip: clip, generation: media.thumbnailGeneration)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        Text(clip.name).font(.headline).textSelection(.enabled)
        actions
        TextField("Beschreibung", text: $description, prompt: Text("Was ist zu sehen?"), axis: .vertical)
            .lineLimit(2...6)
            .textFieldStyle(.roundedBorder)
            .focused($focus, equals: .description)
            .onSubmit(commitDescription)
            .accessibilityIdentifier("clip.description")
        TextField("Schlagwörter", text: $tags, prompt: Text("Schlagwörter, mit Komma getrennt"))
            .textFieldStyle(.roundedBorder)
            .focused($focus, equals: .tags)
            .onSubmit(commitTags)
            .accessibilityIdentifier("clip.tags")
        HStack {
            StarRating(rating: clip.rating) { run(SetClipRating(clipID: clip.id, rating: $0)) }
            Spacer()
            Toggle(
                "Nie verwenden",
                isOn: Binding(get: { clip.excluded }, set: { run(SetClipExcluded(clipID: clip.id, excluded: $0)) })
            )
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("clip.excluded")
            .help("Der automatische Schnitt nutzt diesen Clip nicht.")
        }
        if media.missingClipIDs.contains(clip.id) {
            Label(
                "Die Datei fehlt. „Ablage → Medien neu verknüpfen …“ sucht sie in einem Ordner.",
                systemImage: "questionmark.folder"
            )
            .font(.callout).foregroundStyle(.red)
        }
        if !clip.meta.warnings.isEmpty {
            InspectorSection("Hinweise") {
                ForEach(clip.meta.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
            }
        }
        if !clip.scenes.isEmpty {
            InspectorSection("Szenen (\(clip.scenes.count))") {
                ForEach(clip.scenes) { scene in
                    SceneRow(clip: clip, scene: scene, generation: media.thumbnailGeneration)
                }
            }
        }
        InspectorSection("Technik") {
            Fact("Dauer", Format.duration(clip.meta.duration))
            Fact("Bildrate", "\(Format.fps(clip.meta.fps)) fps")
            Fact(
                "Größe",
                "\(clip.meta.width)×\(clip.meta.height)" + (clip.meta.rotation == 0 ? "" : " · \(clip.meta.rotation)°"))
            if let codec = clip.meta.codec { Fact("Codec", codec) }
            Fact("Timecode", clip.meta.startTimecode ?? "–")
            Fact("Bildrate konstant", clip.meta.isVFR.map { $0 ? "nein" : "ja" } ?? "nicht geprüft")
            Fact("Ton", clip.meta.hasAudio.map { $0 ? "ja" : "nein" } ?? "–")
            if let bytes = clip.meta.sizeBytes { Fact("Dateigröße", Format.bytes(UInt64(bytes))) }
            if project.usageCount(of: clip.id) > 0 { Fact("Im Schnitt", "\(project.usageCount(of: clip.id))×") }
        }
        if let original = clip.original {
            Text("Arbeitskopie von \(original.path)").font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
        }
        Text(clip.media.path).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
            .onAppear(perform: load)
            .onChange(of: clip.id) { _, _ in load() }
            .onChange(of: clip.description) { _, _ in if focus != .description { description = clip.description } }
            .onChange(of: clip.tags) { _, _ in if focus != .tags { tags = clip.tags.joined(separator: ", ") } }
            .onChange(of: focus) { old, _ in
                if old == .description { commitDescription() }
                if old == .tags { commitTags() }
            }
    }

    private var actions: some View {
        HStack {
            Button("Im Finder zeigen", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: clip.media.path)])
            }
            if clip.meta.needsConversion || clip.meta.isVFR == true {
                Button("Arbeitskopie erstellen", systemImage: "arrow.triangle.2.circlepath") {
                    media.createWorkingCopy(for: clip.id)
                }
                .help(
                    clip.meta.needsConversion
                        ? "Wandelt das Format um (ffmpeg)." : "Erstellt eine Kopie mit konstanter Bildrate."
                )
                .accessibilityIdentifier("clip.workingCopy")
            }
            Button("Neu analysieren", systemImage: "arrow.clockwise") { media.analyze([clip.id]) }
                .disabled(media.busyClips.contains(clip.id) || clip.meta.needsConversion)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    private func load() {
        description = clip.description
        tags = clip.tags.joined(separator: ", ")
    }

    private func commitDescription() {
        if description != clip.description { run(SetClipDescription(clipID: clip.id, description: description)) }
    }

    private func commitTags() {
        let list = tags.split(separator: ",").map(String.init)
        if list.map({ $0.trimmingCharacters(in: .whitespaces) }) != clip.tags {
            run(SetClipTags(clipID: clip.id, tags: list))
        }
    }
}

private struct SceneRow: View {
    var clip: Clip
    var scene: ClipScene
    var generation: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CachedImage(url: clip.thumbnailURL(scene: scene), generation: generation)
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Format.time(scene.start)) – \(Format.time(scene.end))").monospacedDigit().font(.callout)
                if let features = scene.features {
                    Text(summary(features)).font(.caption).foregroundStyle(.secondary)
                }
                if !scene.description.isEmpty {
                    Text(scene.description).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func summary(_ features: SceneFeatures) -> String {
        var parts = [features.shotSize.title]
        if features.faceCount > 0 {
            parts.append(features.faceCount == 1 ? "1 Gesicht" : "\(features.faceCount) Gesichter")
        }
        if let aesthetics = features.aesthetics {
            parts.append("Ästhetik \(aesthetics.formatted(.number.precision(.fractionLength(1))))")
        }
        parts.append(features.motion > 0.04 ? "viel Bewegung" : features.motion > 0.01 ? "Bewegung" : "ruhig")
        if features.isUtility { parts.append("Gebrauchsbild") }
        return parts.joined(separator: " · ")
    }
}

/// Bewertung mit 1–5 Sternen; ein Klick auf den aktuellen Wert setzt sie zurück.
struct StarRating: View {
    var rating: Int?
    var set: (Int?) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    set(rating == value ? nil : value)
                } label: {
                    Image(systemName: value <= (rating ?? 0) ? "star.fill" : "star")
                        .foregroundStyle(value <= (rating ?? 0) ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(value) Sterne")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bewertung")
        .accessibilityValue(rating.map { "\($0) von 5" } ?? "keine")
    }
}

private struct ProjectInspector: View {
    @ObservedObject var document: ProjectDocument
    var song: SongController
    @Binding var errorMessage: String?
    @Environment(\.undoManager) private var undoManager
    @State private var name = ""
    @State private var lyrics = ""
    @FocusState private var editingLyrics: Bool

    private var project: Project { document.project }

    var body: some View {
        Text("Projekt").font(.headline)
        TextField("Name", text: $name)
            .textFieldStyle(.roundedBorder)
            .onSubmit(rename)
            .accessibilityIdentifier("project.name")
            .onAppear { name = project.name }
            .onChange(of: project.name) { _, new in name = new }

        InspectorSection("Timeline") {
            Fact("Format", "\(project.timeline.width)×\(project.timeline.height)")
            Fact("Bildrate", "\(Format.fps(project.timeline.fps)) fps")
            Fact("Bildanpassung", project.timeline.fit.title)
        }
        InspectorSection("Song") {
            if let file = project.song { Fact("Datei", file.fileName) }
            if let analysis = project.analysis {
                Fact("Dauer", Format.time(analysis.duration))
                if analysis.tempo > 0 { Fact("Tempo", "\(Int(analysis.tempo.rounded())) BPM · \(analysis.meter)/4") }
                Fact("Beats", "\(analysis.beats.count) (\(analysis.beats.filter(\.isDownbeat).count) Takte)")
                Fact("Abschnitte", "\(analysis.sections.count)")
                Fact(
                    "Wörter",
                    analysis.words.isEmpty
                        ? "–" : "\(analysis.words.count), \(analysis.words.filter(\.isUncertain).count) unsicher")
                if let model = analysis.transcriptionModel { Fact("Erkannt mit", model) }
            } else if project.song != nil {
                Text(song.analyzing ? "Wird analysiert …" : "Noch nicht analysiert").foregroundStyle(.secondary)
            } else {
                Text("Song per Drag-and-Drop oder ⇧⌘I hinzufügen.").foregroundStyle(.secondary)
            }
            if project.song != nil {
                HStack {
                    Button("Neu analysieren") { song.analyze() }
                        .disabled(song.analyzing)
                        .help("Beats und Abschnitte neu erkennen; Rasterkorrekturen gehen dabei verloren.")
                    Button("Gesang erkennen") { song.transcribe() }
                        .disabled(song.transcribing || project.analysis == nil)
                        .help(
                            SongController.transcriptionInstalled
                                ? "Wörter mit Zeiten erkennen (lokal)"
                                : "Erst das Modell laden (Einstellungen → Modelle)"
                        )
                        .accessibilityIdentifier("song.transcribe")
                }
                .controlSize(.small)
            }
        }
        InspectorSection("Songtext") {
            TextEditor(text: $lyrics)
                .font(.callout)
                .frame(minHeight: 90, maxHeight: 220)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .focused($editingLyrics)
                .accessibilityIdentifier("song.lyrics")
            Text("Absätze oder Überschriften wie [Refrain] werden zu Abschnitten; gleicher Text heißt Wiederholung.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Songtext ausrichten") {
                commitLyrics()
                song.alignLyrics()
            }
            .controlSize(.small)
            .disabled(project.analysis == nil)
            .accessibilityIdentifier("song.align")
        }
        .onAppear { lyrics = project.lyricsText }
        .onChange(of: project.lyricsText) { _, new in if !editingLyrics { lyrics = new } }
        .onChange(of: editingLyrics) { _, editing in if !editing { commitLyrics() } }
        if let cut = project.cut {
            InspectorSection("Schnitt") {
                Fact("Variante", cut.name)
                Fact("Einstellungen", "\(cut.shots.count)")
                Fact("Fixiert", "\(cut.shots.filter(\.locked).count)")
            }
        }
        if let legacy = project.legacy, !legacy.notes.isEmpty {
            InspectorSection("Hinweise zur Übernahme") {
                ForEach(legacy.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.callout)
                }
            }
        }
    }

    private func commitLyrics() {
        guard lyrics != project.lyricsText else { return }
        errorMessage = document.run(SetLyrics(text: lyrics), undoManager: undoManager)
    }

    private func rename() {
        guard name != project.name else { return }
        errorMessage = document.run(RenameProject(name: name), undoManager: undoManager)
        if errorMessage != nil { name = project.name }
    }
}

struct InspectorSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

struct Fact: View {
    var label: String
    var value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).monospacedDigit().textSelection(.enabled)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}
