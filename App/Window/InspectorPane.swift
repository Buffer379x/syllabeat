import SwiftUI
import SyllaBeatCore

/// Inspektor: zeigt den ausgewählten Clip oder, ohne Auswahl, das Projekt.
struct InspectorPane: View {
    @ObservedObject var document: ProjectDocument
    var selectedClipID: String?
    @Binding var errorMessage: String?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let id = selectedClipID, let clip = document.project.clip(withID: id) {
                    ClipInspector(clip: clip) { excluded in
                        errorMessage = document.run(
                            SetClipExcluded(clipID: clip.id, excluded: excluded), undoManager: undoManager)
                    }
                } else {
                    ProjectInspector(document: document, errorMessage: $errorMessage)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Neue Auswahl beginnt oben statt an der alten Scrollposition.
        .id(selectedClipID ?? "projekt")
        .background(.background)
        .accessibilityIdentifier("inspector")
    }
}

private struct ClipInspector: View {
    var clip: Clip
    var setExcluded: (Bool) -> Void

    var body: some View {
        Text(clip.name).font(.headline).textSelection(.enabled)
        if !clip.description.isEmpty {
            Text(clip.description).fixedSize(horizontal: false, vertical: true)
        }
        if !clip.tags.isEmpty {
            Text(clip.tags.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
        }
        Toggle(
            "Nie verwenden",
            isOn: Binding(get: { clip.excluded }, set: { setExcluded($0) })
        )
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("clip.excluded")
        .help("Der automatische Schnitt nutzt diesen Clip nicht.")

        InspectorSection("Technik") {
            Fact("Dauer", Format.duration(clip.meta.duration))
            Fact("Bildrate", "\(Format.fps(clip.meta.fps)) fps")
            Fact(
                "Größe",
                "\(clip.meta.width)×\(clip.meta.height)" + (clip.meta.rotation == 0 ? "" : " · \(clip.meta.rotation)°"))
            if let codec = clip.meta.codec { Fact("Codec", codec) }
            Fact("Timecode", clip.meta.startTimecode ?? "–")
            Fact("Bildrate konstant", clip.meta.isVFR.map { $0 ? "nein" : "ja" } ?? "nicht geprüft")
        }
        if !clip.meta.warnings.isEmpty {
            InspectorSection("Hinweise") {
                ForEach(clip.meta.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
            }
        }
        if !clip.scenes.isEmpty {
            InspectorSection("Szenen") {
                ForEach(clip.scenes) { scene in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Format.time(scene.start)) – \(Format.time(scene.end))").monospacedDigit().font(.callout)
                        if !scene.description.isEmpty {
                            Text(scene.description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        Text(clip.media.path).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
    }
}

private struct ProjectInspector: View {
    @ObservedObject var document: ProjectDocument
    @Binding var errorMessage: String?
    @Environment(\.undoManager) private var undoManager
    @State private var name = ""

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
        }
        InspectorSection("Song") {
            if let song = project.song { Fact("Datei", song.fileName) }
            if let analysis = project.analysis {
                Fact("Dauer", Format.time(analysis.duration))
                if analysis.tempo > 0 { Fact("Tempo", "\(Int(analysis.tempo.rounded())) BPM") }
                Fact("Beats", "\(analysis.beats.count)")
                Fact("Textzeilen", "\(analysis.lines.count)")
                Fact("Abschnitte", "\(analysis.sections.count)")
            } else {
                Text("Noch nicht analysiert").foregroundStyle(.secondary)
            }
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
