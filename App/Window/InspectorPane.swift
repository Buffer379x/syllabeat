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
    var ai: AIController
    var selectedClipID: String?
    var selectedClipIDs: Set<String> = []
    @Binding var errorMessage: String?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let shot = cut.selectedShot {
                    ShotInspector(shot: shot, project: document.project, media: media, cut: cut)
                } else if selectedClipIDs.count > 1 {
                    MultiClipInspector(
                        clips: document.project.clips.filter { selectedClipIDs.contains($0.id) },
                        project: document.project,
                        textScores: cut.textScores
                    ) { command in
                        errorMessage = document.run(command, undoManager: undoManager)
                    }
                } else if let id = selectedClipID, let clip = document.project.clip(withID: id) {
                    ClipInspector(
                        clip: clip, project: document.project, media: media, ai: ai, textScores: cut.textScores,
                        view: { cut.view(clipID: clip.id) }
                    ) { command in
                        errorMessage = document.run(command, undoManager: undoManager)
                    }
                } else {
                    ProjectInspector(document: document, song: song, ai: ai, errorMessage: $errorMessage)
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
    var ai: AIController
    var textScores: TextScores
    var view: () -> Void
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
        // Schnelle Entscheidungen oben, die Beschreibung darunter.
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
        if !project.story.chapters.isEmpty {
            ChapterPicker(
                clipIDs: [clip.id], current: clip.chapterID, project: project, textScores: textScores, run: run)
        }
        TimeOfDayPicker(clips: [clip], project: project, textScores: textScores, run: run)
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
        if let mood = clip.mood, !mood.isEmpty {
            Label("Stimmung: \(mood)", systemImage: "theatermasks").font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(alignment: .firstTextBaseline) {
            if let model = clip.visionModel {
                Text("Beschrieben von \(model)" + (clip.filenameSuggestion.map { " · Vorschlag: \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.tertiary)
                    .accessibilityIdentifier("clip.describedBy")
            }
            Spacer()
            Button(clip.description.isEmpty ? "Beschreiben" : "Neu beschreiben", systemImage: "text.viewfinder") {
                ai.describe([clip.id], replacing: !clip.description.isEmpty)
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(ai.describing || clip.scenes.isEmpty)
            .help("Bildbeschreibung mit dem gewählten Anbieter (Einstellungen → Anbieter)")
            .accessibilityIdentifier("clip.describe")
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
        InspectorSection("Sperrbereiche (\(clip.blocked.count))") {
            ForEach(Array(clip.blocked.enumerated()), id: \.offset) { index, range in
                HStack {
                    Image(systemName: "nosign").foregroundStyle(.red)
                    Text("\(Format.time(range.start)) – \(Format.time(range.end))").monospacedDigit()
                    Spacer()
                    Button {
                        var ranges = clip.blocked
                        ranges.remove(at: index)
                        run(SetBlockedRanges(clipID: clip.id, ranges: ranges))
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Sperre entfernen")
                    .accessibilityLabel("Sperre entfernen")
                }
                .font(.callout)
                .accessibilityIdentifier("clip.blocked.\(index)")
            }
            Button("Sichten und sperren …", systemImage: "eye", action: view)
                .controlSize(.small)
                .help("Clip groß abspielen und Fehlerstellen mit I/O/X sperren (Doppelklick in der Bibliothek)")
                .accessibilityIdentifier("clip.review")
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
    var ai: AIController
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
            TimelineFormatEditor(project: project) { command in
                errorMessage = document.run(command, undoManager: undoManager)
            }
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
        DirectorSection(project: project, ai: ai) { command in
            errorMessage = document.run(command, undoManager: undoManager)
        }
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

/// Format, Bildrate und Bildanpassung der Timeline mit Vorschlag aus dem Material.
struct TimelineFormatEditor: View {
    var project: Project
    var run: (any EditCommand) -> Void

    private var timeline: TimelineSettings { project.timeline }

    var body: some View {
        Picker("Format", selection: sizeBinding) {
            ForEach(TimelineSettings.presets, id: \.title) { preset in
                Text("\(preset.title) · \(preset.width)×\(preset.height)").tag("\(preset.width)x\(preset.height)")
            }
            if !TimelineSettings.presets.contains(where: { $0.width == timeline.width && $0.height == timeline.height })
            {
                Text("\(timeline.width)×\(timeline.height)").tag("\(timeline.width)x\(timeline.height)")
            }
        }
        .accessibilityIdentifier("timeline.size")
        Picker("Bildrate", selection: rateBinding) {
            ForEach(rates, id: \.self) { rate in Text("\(Format.fps(rate)) fps").tag(rate) }
        }
        .accessibilityIdentifier("timeline.rate")
        Picker("Bildanpassung", selection: Binding(get: { timeline.fit }, set: { run(SetFit(fit: $0)) })) {
            ForEach(TimelineSettings.Fit.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        let suggested = TimelineSettings.suggested(for: project.clips, current: timeline)
        if suggested != timeline {
            Text(
                "Vorschlag aus dem Material: \(suggested.width)×\(suggested.height) · \(Format.fps(suggested.fps)) fps"
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var rates: [Rational] {
        TimelineSettings.rates.contains(timeline.fps) ? TimelineSettings.rates : TimelineSettings.rates + [timeline.fps]
    }

    private var rateBinding: Binding<Rational> {
        Binding(
            get: { timeline.fps },
            set: { rate in
                var settings = timeline
                settings.fps = rate
                run(SetTimelineSettings(settings: settings))
            })
    }

    private var sizeBinding: Binding<String> {
        Binding(
            get: { "\(timeline.width)x\(timeline.height)" },
            set: { tag in
                let parts = tag.split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2 else { return }
                var settings = timeline
                (settings.width, settings.height) = (parts[0], parts[1])
                run(SetTimelineSettings(settings: settings))
            })
    }
}

/// Kapitel für einen oder mehrere Clips.
struct ChapterPicker: View {
    var clipIDs: Set<String>
    var current: String?
    var project: Project
    var textScores: TextScores
    var run: (any EditCommand) -> Void

    var body: some View {
        Picker(
            "Kapitel",
            selection: Binding(
                get: { current ?? "" },
                set: { id in
                    run(
                        AssignChapter(
                            clipIDs: clipIDs, chapterID: id.isEmpty ? nil : id, includeTakes: false,
                            textScores: textScores))
                })
        ) {
            Text("Ohne Kapitel").tag("")
            ForEach(project.story.chapters) { chapter in Text(chapter.name).tag(chapter.id) }
        }
        .accessibilityIdentifier("clip.chapter")
    }
}

/// Inspektor bei mehreren ausgewählten Clips: gemeinsame Zuordnungen für alle.
struct MultiClipInspector: View {
    var clips: [Clip]
    var project: Project
    var textScores: TextScores
    var run: (any EditCommand) -> Void

    var body: some View {
        Text("\(clips.count) Clips").font(.headline).accessibilityIdentifier("inspector.multi")
        let ids = Set(clips.map(\.id))
        let chapters = Set(clips.map(\.chapterID))
        if !project.story.chapters.isEmpty {
            ChapterPicker(
                clipIDs: ids, current: chapters.count == 1 ? chapters.first ?? nil : nil, project: project,
                textScores: textScores, run: run)
        } else {
            Text("Kapitel legst du per Rechtsklick in der Bibliothek an („Kapitel ▸ Neues Kapitel …“).")
                .font(.callout).foregroundStyle(.secondary)
        }
        TimeOfDayPicker(clips: clips, project: project, textScores: textScores, run: run)
    }
}

/// Symbole und Texte für die Tageszeit.
enum TimeOfDaySymbol {
    static func name(_ value: String) -> String {
        switch value {
        case "Abend": "sunset"
        case "Nacht": "moon.stars"
        default: "sun.max"
        }
    }

    static func source(_ source: TraitValue.Source) -> String {
        switch source {
        case .user: "von dir"
        case .fileName: "aus Dateiname"
        case .description: "aus Beschreibung"
        }
    }
}

/// Tageszeit für einen oder mehrere Clips: „Automatisch“ zeigt, was die App erkannt hat und woher.
struct TimeOfDayPicker: View {
    var clips: [Clip]
    var project: Project
    var textScores: TextScores
    var run: (any EditCommand) -> Void

    private var userValue: String {
        let values = Set(
            clips.map { clip in
                clip.traits[Trait.timeOfDay.id].flatMap { $0.source == .user ? $0.value : nil } ?? ""
            })
        return values.count == 1 ? values.first ?? "" : ""
    }

    private var automatic: String {
        guard clips.count == 1, var probe = clips.first else { return "Automatisch" }
        probe.traits[Trait.timeOfDay.id] = probe.traits[Trait.timeOfDay.id].flatMap { $0.source == .user ? nil : $0 }
        guard let found = StoryResolver.value(.timeOfDay, for: probe, in: project) else { return "Automatisch (offen)" }
        return "Automatisch (\(found.value) · \(TimeOfDaySymbol.source(found.source)))"
    }

    var body: some View {
        Picker(
            "Tageszeit",
            selection: Binding(
                get: { userValue },
                set: { value in
                    run(
                        SetTraitValue(
                            clipIDs: Set(clips.map(\.id)), traitID: Trait.timeOfDay.id,
                            value: value.isEmpty ? nil : value, textScores: textScores))
                })
        ) {
            Text(automatic).tag("")
            ForEach(Trait.timeOfDay.values, id: \.self) { Text($0).tag($0) }
        }
        .accessibilityIdentifier("clip.timeOfDay")
    }
}
