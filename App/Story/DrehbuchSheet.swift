import SwiftUI
import SyllaBeatAI
import SyllaBeatCore
import SyllaBeatUI

/// Drehbuch-Tafel: links die Kapitel in Erzählreihenfolge, rechts je Songabschnitt, welche Kapitel vorkommen
/// (● Hauptkapitel, ◐ Beimischung, · nicht). Jede Änderung schneidet sofort neu; fixierte Einstellungen bleiben.
struct DrehbuchSheet: View {
    var project: Project
    var textScores: TextScores
    var run: (any EditCommand) -> Void
    var close: () -> Void
    @State private var newName = ""

    private var story: Story { project.story }

    /// Spalten: Abschnitte in Songreihenfolge; Wiederholungen ohne eigenen Eintrag teilen die Spalte der Vorlage.
    private var columns: [SongSection] {
        (project.analysis?.sections ?? []).sorted { $0.start < $1.start }.filter {
            $0.repeatOf == nil || story.plan[$0.id] != nil
        }
    }

    private var montage: Set<String> {
        let sections = project.analysis?.sections ?? []
        return story.montage ?? Set(sections.compactMap(\.repeatOf) + sections.filter { $0.repeatOf != nil }.map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drehbuch").font(.title3.weight(.semibold))
            if columns.isEmpty {
                Text("Für das Drehbuch zuerst den Song analysieren.").foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    chapterList.frame(width: 220)
                    ScrollView(.horizontal) { matrix }
                }
            }
            HStack {
                Text("● Hauptkapitel  ◐ Beimischung  · nicht").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Vorschlagen", systemImage: "wand.and.stars", action: propose)
                    .disabled(story.chapters.isEmpty || columns.isEmpty)
                    .help("Kapitel den Abschnitten in Erzählreihenfolge zuordnen (aus Songtext und Bildähnlichkeit)")
                    .accessibilityIdentifier("drehbuch.propose")
                Button("Fertig", action: close).keyboardShortcut(.defaultAction).accessibilityIdentifier(
                    "drehbuch.done")
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 360)
        .accessibilityIdentifier("drehbuch")
    }

    private var chapterList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("KAPITEL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(story.chapters.enumerated()), id: \.element.id) { index, chapter in
                ChapterRow(
                    chapter: chapter, count: project.clips.filter { $0.chapterID == chapter.id }.count,
                    canMoveUp: index > 0, canMoveDown: index < story.chapters.count - 1,
                    setTime: { value in
                        run(
                            SetChapterTrait(
                                chapterID: chapter.id, traitID: Trait.timeOfDay.id, value: value,
                                textScores: textScores))
                    }
                ) { change in
                    var chapters = story.chapters
                    switch change {
                    case .rename(let name): chapters[index].name = name
                    case .move(let offset): chapters.swapAt(index, index + offset)
                    case .delete: chapters.remove(at: index)
                    }
                    run(SetChapters(chapters: chapters, textScores: textScores))
                }
            }
            HStack {
                TextField("Neues Kapitel", text: $newName).onSubmit(add).accessibilityIdentifier("drehbuch.newChapter")
                Button("Hinzufügen", systemImage: "plus", action: add).labelStyle(.iconOnly)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var matrix: some View {
        Grid(alignment: .center, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("")
                ForEach(columns) { section in
                    Text(title(section)).font(.caption.weight(.semibold)).lineLimit(1).frame(minWidth: 64)
                }
            }
            ForEach(story.chapters) { chapter in
                GridRow {
                    Text(chapter.name).font(.callout).lineLimit(1).frame(maxWidth: 110, alignment: .leading)
                    ForEach(columns) { section in cell(section, chapter) }
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            GridRow {
                Text("Tageszeit").font(.callout).frame(maxWidth: 110, alignment: .leading)
                ForEach(columns) { section in
                    Picker(
                        "Tageszeit",
                        selection: Binding(
                            get: { story.traits.first { $0.id == Trait.timeOfDay.id }?.pinned[section.id] ?? "" },
                            set: { value in
                                run(
                                    SetTraitPin(
                                        traitID: Trait.timeOfDay.id, sectionID: section.id,
                                        value: value.isEmpty ? nil : value, textScores: textScores))
                            })
                    ) {
                        Text("auto").tag("")
                        ForEach(Trait.timeOfDay.values, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 72)
                    .help("Tageszeit für diesen Abschnitt festlegen (sonst läuft sie vorwärts: Tag → Abend → Nacht)")
                }
            }
            GridRow {
                Text("Montage").font(.callout).frame(maxWidth: 110, alignment: .leading)
                ForEach(columns) { section in
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { montage.contains(section.id) },
                            set: { on in
                                run(SetMontage(sectionID: section.id, on: on, textScores: textScores))
                            })
                    )
                    .labelsHidden()
                    .help("Montage: kommt in der Geschichte nicht voran (Standard: Refrains)")
                }
            }
        }
    }

    private func cell(_ section: SongSection, _ chapter: Chapter) -> some View {
        let role = story.plan[section.id]?[chapter.id]
        let symbol = role == .main ? "●" : role == .mix ? "◐" : "·"
        return Button(symbol) {
            let next: ChapterRole? =
                switch role {
                case nil: .mix
                case .mix: .main
                case .main: nil
                }
            run(SetChapterRole(sectionID: section.id, chapterID: chapter.id, role: next, textScores: textScores))
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .foregroundStyle(role == nil ? Color.secondary : Color(nsColor: ChapterPalette.color(chapter.color)))
        .frame(minWidth: 64)
        .accessibilityLabel(
            "\(chapter.name) in \(section.label): \(role == .main ? "Hauptkapitel" : role == .mix ? "Beimischung" : "nicht")"
        )
        .accessibilityIdentifier("drehbuch.cell.\(section.id).\(chapter.id)")
    }

    private func title(_ section: SongSection) -> String {
        let count = (project.analysis?.sections ?? []).filter {
            $0.id == section.id || ($0.repeatOf == section.id && story.plan[$0.id] == nil)
        }.count
        return count > 1 ? "\(section.label) ●×\(count)" : section.label
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let chapter = Chapter(
            id: "k-\(UUID().uuidString.prefix(8).lowercased())", name: name, color: story.chapters.count)
        run(SetChapters(chapters: story.chapters + [chapter], textScores: textScores))
        newName = ""
    }

    private func propose() {
        let plan = DrehbuchProposer.plan(
            sections: project.analysis?.sections ?? [], chapters: story.chapters,
            evidence: StoryScores.chapterEvidence(project, rows: textScores.values), montage: montage)
        run(ApplyDrehbuch(plan: plan, textScores: textScores))
    }
}

private struct ChapterRow: View {
    enum Change { case rename(String), move(Int), delete }

    var chapter: Chapter
    var count: Int
    var canMoveUp: Bool
    var canMoveDown: Bool
    var setTime: (String?) -> Void
    var change: (Change) -> Void
    @State private var name = ""

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color(nsColor: ChapterPalette.color(chapter.color))).frame(width: 9, height: 9)
            if let time = chapter.traits[Trait.timeOfDay.id] {
                Image(systemName: TimeOfDaySymbol.name(time)).font(.caption).help("Vorgabe: \(time)")
            }
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .onSubmit { if !name.isEmpty, name != chapter.name { change(.rename(name)) } }
                .onAppear { name = chapter.name }
                .onChange(of: chapter.name) { _, new in name = new }
            Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button("Nach oben", systemImage: "chevron.up") { change(.move(-1)) }.disabled(!canMoveUp)
            Button("Nach unten", systemImage: "chevron.down") { change(.move(1)) }.disabled(!canMoveDown)
            Button("Entfernen", systemImage: "trash") { change(.delete) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .contextMenu {
            Menu("Tageszeit vorgeben") {
                ForEach(Trait.timeOfDay.values, id: \.self) { value in Button(value) { setTime(value) } }
                Divider()
                Button("Keine Vorgabe") { setTime(nil) }
            }
        }
    }
}
