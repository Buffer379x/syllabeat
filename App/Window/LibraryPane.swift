import SwiftUI
import SyllaBeatCore
import SyllaBeatUI

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, unused, used, favorites, warnings, excluded, day, evening, night, timeOpen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Alle Clips"
        case .unused: "Unbenutzt"
        case .used: "Im Schnitt"
        case .favorites: "Favoriten"
        case .warnings: "Mit Hinweisen"
        case .excluded: "Nie verwenden"
        case .day: "Tag"
        case .evening: "Abend"
        case .night: "Nacht"
        case .timeOpen: "Tageszeit offen"
        }
    }

    func includes(_ clip: Clip, in project: Project, missing: Set<String>) -> Bool {
        switch self {
        case .all: true
        case .unused: project.usageCount(of: clip.id) == 0
        case .used: project.usageCount(of: clip.id) > 0
        case .favorites: (clip.rating ?? 0) >= 4
        case .warnings: clip.hasWarnings || missing.contains(clip.id)
        case .excluded: clip.excluded
        case .day: StoryResolver.value(.timeOfDay, for: clip, in: project)?.value == "Tag"
        case .evening: StoryResolver.value(.timeOfDay, for: clip, in: project)?.value == "Abend"
        case .night: StoryResolver.value(.timeOfDay, for: clip, in: project)?.value == "Nacht"
        case .timeOpen: StoryResolver.value(.timeOfDay, for: clip, in: project) == nil
        }
    }
}

extension Clip {
    var hasWarnings: Bool { !meta.warnings.isEmpty || meta.isVFR == true || meta.needsConversion }
}

/// Bibliothek: Raster oder Liste mit Vorschaubildern, Filter, Suche (Text sofort, Bildsuche nach kurzer Pause).
struct LibraryPane: View {
    var project: Project
    var media: MediaController
    @Binding var selection: Set<String>
    /// Kapitel zuweisen (`nil` = ohne) und neues Kapitel anlegen; das Fenster baut die Befehle.
    var assign: (Set<String>, String?) -> Void = { _, _ in }
    var createChapter: (String, Set<String>) -> Void = { _, _ in }
    /// Kapitel-Vorschläge übernehmen (Clip-ID → Kapitel-ID).
    var acceptSuggestions: ([String: String]) -> Void = { _ in }
    /// Tageszeit setzen (`nil` = automatisch).
    var setTime: (Set<String>, String?) -> Void = { _, _ in }
    /// Doppelklick: Clip in der Clip-Ansicht öffnen.
    var open: (String) -> Void = { _ in }
    @AppStorage("libraryByChapter") private var byChapter = true
    @State private var showsNewChapter = false
    @State private var newChapterName = ""
    @State private var pendingClipIDs: Set<String> = []
    @State private var query = ""
    @AppStorage("libraryFilter") private var filter = LibraryFilter.all
    @AppStorage("libraryShowsGrid") private var showsGrid = true
    @AppStorage("libraryShotSize") private var shotSize = ""

    private var visible: [Clip] {
        let missing = media.missingClipIDs
        var clips = project.clips.filter { clip in
            filter.includes(clip, in: project, missing: missing)
                && (shotSize.isEmpty || clip.scenes.contains { $0.features?.shotSize.rawValue == shotSize })
        }
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return clips }
        let textMatches = Set(
            clips.filter { clip in
                let haystack =
                    ([clip.name, clip.description, clip.mood ?? ""] + clip.tags
                    + clip.scenes.map(\.description)).joined(separator: " ").lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }.map(\.id))
        if let ranking = media.semanticRanking {
            let order = Dictionary(uniqueKeysWithValues: ranking.enumerated().map { ($1, $0) })
            clips.sort { a, b in
                let ta = textMatches.contains(a.id)
                let tb = textMatches.contains(b.id)
                if ta != tb { return ta }
                return order[a.id, default: .max] < order[b.id, default: .max]
            }
            return clips
        }
        return clips.filter { textMatches.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if project.clips.isEmpty {
                DropHint(
                    title: "Clips oder Ordner hierher ziehen", systemImage: "film.stack",
                    detail: "Videos werden eingelesen, in Szenen zerlegt und für die Bildsuche vorbereitet.")
                Button("Clips wählen …") { media.presentImportPanel() }
                    .padding(.bottom, 20)
            } else {
                header
                let clips = visible
                if clips.isEmpty, media.preparingSearch {
                    ContentUnavailableView(
                        "Bildsuche wird vorbereitet", systemImage: "photo.badge.magnifyingglass",
                        description: Text("Gleich findet die Suche auch Clips nach ihrem Bildinhalt."))
                } else if clips.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if showsGrid {
                    grid(clips)
                } else {
                    list(clips)
                }
                Divider()
                Text(footer(clips.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onChange(of: query) { _, text in media.search(text) }
        .onChange(of: media.sceneIndex?.count) { _, _ in media.search(query) }
    }

    private var header: some View {
        VStack(spacing: 6) {
            TextField(
                "Suchen", text: $query,
                prompt: Text(
                    media.searchAvailable ? "Suchen, z. B. „Meer bei Nacht“" : "Name, Beschreibung, Schlagwort")
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("library.search")
            HStack(spacing: 6) {
                Picker("Filter", selection: $filter) {
                    ForEach(LibraryFilter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .accessibilityIdentifier("library.filter")
                Picker("Einstellungsgröße", selection: $shotSize) {
                    Text("Alle Größen").tag("")
                    ForEach(ShotSize.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                Spacer(minLength: 0)
                if !project.story.chapters.isEmpty {
                    Toggle(isOn: $byChapter) { Image(systemName: "rectangle.3.group") }
                        .toggleStyle(.button)
                        .help("Nach Kapitel gruppieren")
                        .accessibilityIdentifier("library.byChapter")
                }
                Picker("Ansicht", selection: $showsGrid) {
                    Image(systemName: "square.grid.2x2").tag(true).accessibilityLabel("Raster")
                    Image(systemName: "list.bullet").tag(false).accessibilityLabel("Liste")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .controlSize(.small)
        }
        .padding(8)
    }

    private static let columns = [GridItem(.adaptive(minimum: 120, maximum: 220), spacing: 8)]

    private func grid(_ clips: [Clip]) -> some View {
        ScrollView {
            if byChapter, !project.story.chapters.isEmpty {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groups(clips), id: \.id) { group in
                        HStack(spacing: 6) {
                            Circle().fill(group.color).frame(width: 9, height: 9)
                            Text("\(group.name) · \(group.clips.count)").font(.callout.weight(.semibold))
                            if group.id == "ohne", !suggestions.isEmpty {
                                Spacer()
                                Button("Vorschläge übernehmen (\(suggestions.count))") {
                                    acceptSuggestions(suggestions.mapValues(\.chapterID))
                                }
                                .controlSize(.small)
                                .help("Kapitel nach Motiv (sicher) bzw. Bildähnlichkeit (mit „?“) zuweisen")
                                .accessibilityIdentifier("library.acceptSuggestions")
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("library.group.\(group.id)")
                        LazyVGrid(columns: Self.columns, spacing: 10) { ForEach(group.clips) { tile($0) } }
                    }
                }
                .padding(8)
            } else {
                LazyVGrid(columns: Self.columns, spacing: 10) { ForEach(clips) { tile($0) } }
                    .padding(8)
            }
        }
        .accessibilityIdentifier("library.grid")
        .alert("Neues Kapitel", isPresented: $showsNewChapter) {
            TextField("Name", text: $newChapterName)
            Button("Anlegen") {
                let name = newChapterName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { createChapter(name, pendingClipIDs) }
                newChapterName = ""
            }
            Button("Abbrechen", role: .cancel) { newChapterName = "" }
        } message: {
            Text("Die ausgewählten Clips kommen in das neue Kapitel.")
        }
    }

    private struct Group {
        var id: String
        var name: String
        var color: Color
        var clips: [Clip]
    }

    /// Clips nach Kapitel in Erzählreihenfolge, zuletzt „Ohne Kapitel“.
    private func groups(_ clips: [Clip]) -> [Group] {
        var result = project.story.chapters.map { chapter in
            Group(
                id: chapter.id, name: chapter.name, color: Color(nsColor: ChapterPalette.color(chapter.color)),
                clips: clips.filter { $0.chapterID == chapter.id })
        }
        let known = Set(project.story.chapters.map(\.id))
        let rest = clips.filter { !($0.chapterID.map(known.contains) ?? false) }
        if !rest.isEmpty { result.append(Group(id: "ohne", name: "Ohne Kapitel", color: .secondary, clips: rest)) }
        return result.filter { !$0.clips.isEmpty }
    }

    /// Kapitel-Vorschläge für Clips ohne Kapitel.
    private var suggestions: [String: (chapterID: String, sure: Bool)] {
        guard !project.story.chapters.isEmpty else { return [:] }
        var result: [String: (chapterID: String, sure: Bool)] = [:]
        for clip in project.clips where clip.chapterID == nil {
            if let suggestion = ChapterSuggester.suggest(for: clip, in: project, vectors: media.clipVectors) {
                result[clip.id] = suggestion
            }
        }
        return result
    }

    private func tile(_ clip: Clip) -> some View {
        ClipTile(clip: clip, project: project, media: media, selected: selection.contains(clip.id))
            .overlay(alignment: .bottomTrailing) { suggestionBadge(clip) }
            .onTapGesture(count: 2) { open(clip.id) }
            .onTapGesture { select(clip.id) }
            .contextMenu { menu(targets(clip.id)) }
            .accessibilityAddTraits(selection.contains(clip.id) ? [.isSelected, .isButton] : .isButton)
    }

    /// Klick wählt aus, ⌘- oder ⇧-Klick erweitert die Auswahl.
    private func select(_ id: String) {
        // Tasten des Klicks selbst (zuverlässig auch bei synthetischen Ereignissen), sonst der aktuelle Zustand.
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if flags.contains(.command) || flags.contains(.shift) {
            selection.formSymmetricDifference([id])
        } else {
            selection = [id]
        }
    }

    /// Rechtsklick in die Auswahl wirkt auf alle ausgewählten Clips, sonst nur auf diesen.
    private func targets(_ id: String) -> Set<String> {
        selection.contains(id) ? selection : [id]
    }

    @ViewBuilder
    private func suggestionBadge(_ clip: Clip) -> some View {
        if clip.chapterID == nil,
            let suggestion = ChapterSuggester.suggest(for: clip, in: project, vectors: media.clipVectors),
            let chapter = project.story.chapter(withID: suggestion.chapterID)
        {
            Text("→ \(chapter.name)\(suggestion.sure ? "" : " ?")")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 4)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 22)
                .padding(.trailing, 4)
                .help(
                    suggestion.sure
                        ? "Gleiches Motiv wie Clips in „\(chapter.name)“" : "Ähnlichstes Kapitel – bitte prüfen")
        }
    }

    @ViewBuilder
    private func menu(_ ids: Set<String>) -> some View {
        Menu("Kapitel") {
            ForEach(project.story.chapters) { chapter in
                Button(chapter.name) { assign(ids, chapter.id) }
            }
            if !project.story.chapters.isEmpty { Divider() }
            Button("Neues Kapitel …") {
                pendingClipIDs = ids
                showsNewChapter = true
            }
            Button("Ohne Kapitel") { assign(ids, nil) }
        }
        Menu("Tageszeit") {
            ForEach(Trait.timeOfDay.values, id: \.self) { value in Button(value) { setTime(ids, value) } }
            Divider()
            Button("Automatisch") { setTime(ids, nil) }
        }
        Button("Alle Takes auswählen") {
            let motifs = project.motifs()
            let keys = Set(ids.compactMap { motifs[$0]?.key })
            selection = Set(project.clips.filter { motifs[$0.id].map { keys.contains($0.key) } ?? false }.map(\.id))
        }
    }

    private func list(_ clips: [Clip]) -> some View {
        List(clips, selection: $selection) { clip in
            ClipRow(clip: clip, project: project, media: media).tag(clip.id)
                .contextMenu { menu(targets(clip.id)) }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("library.list")
    }

    private func footer(_ shown: Int) -> String {
        let total = project.clips.reduce(0) { $0 + $1.meta.duration }
        var text = shown == project.clips.count ? "\(shown) Clips" : "\(shown) von \(project.clips.count) Clips"
        text += " · \(Format.time(total)) Material"
        if !media.busyClips.isEmpty { text += " · \(media.busyClips.count) in Analyse" }
        if !query.isEmpty, media.semanticRanking != nil { text += " · nach Bildähnlichkeit sortiert" }
        if media.preparingSearch { text += " · Bildsuche wird vorbereitet" }
        return text
    }
}

private struct ClipTile: View {
    var clip: Clip
    var project: Project
    var media: MediaController
    var selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SkimmingThumbnail(
                clip: clip, generation: media.thumbnailGeneration, sceneStart: media.matchedScenes[clip.id]
            )
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) { ClipBadges(clip: clip, project: project, media: media).padding(4) }
            .overlay(alignment: .bottomLeading) {
                Text(Format.duration(clip.meta.duration))
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 4)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                    .padding(4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6).strokeBorder(
                    selected ? Color.accentColor : .clear, lineWidth: 2.5)
            }
            .opacity(clip.excluded ? 0.45 : 1)
            Text(clip.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .strikethrough(clip.excluded)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(clip.name), \(Format.duration(clip.meta.duration))"
                + (clip.blocked.isEmpty ? "" : ", \(clip.blocked.count) Sperrbereich(e)")
        )
        .accessibilityIdentifier("clip.\(clip.id)")
        // Auf eine Einstellung in der Bildspur ziehen ersetzt deren Clip.
        .draggable("\(TimelineCanvas.clipDragPrefix)\(clip.id)")
    }
}

private struct ClipRow: View {
    var clip: Clip
    var project: Project
    var media: MediaController

    var body: some View {
        HStack(spacing: 10) {
            CachedImage(url: clip.thumbnailURL(), generation: media.thumbnailGeneration)
                .frame(width: 56, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name).lineLimit(1).truncationMode(.middle).strikethrough(clip.excluded)
                Text(info).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
            ClipBadges(clip: clip, project: project, media: media)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("clip.\(clip.id)")
        // Auf eine Einstellung in der Bildspur ziehen ersetzt deren Clip.
        .draggable("\(TimelineCanvas.clipDragPrefix)\(clip.id)")
    }

    private var info: String {
        let scenes = clip.scenes.count == 1 ? "1 Szene" : "\(clip.scenes.count) Szenen"
        return "\(Format.duration(clip.meta.duration)) · \(Format.fps(clip.meta.fps)) fps · \(scenes)"
    }
}

/// Kleine Symbole: in Analyse, im Schnitt ×n, Favorit, Hinweis, fehlt, nie verwenden.
private struct ClipBadges: View {
    var clip: Clip
    var project: Project
    var media: MediaController

    var body: some View {
        HStack(spacing: 3) {
            if media.busyClips.contains(clip.id) {
                ProgressView().controlSize(.mini).help("Wird analysiert")
            }
            let uses = project.usageCount(of: clip.id)
            if uses > 0 { badge("×\(uses)", help: "\(uses)× im Schnitt") }
            if (clip.rating ?? 0) >= 4 { badge(systemImage: "star.fill", color: .yellow, help: "Favorit") }
            if media.missingClipIDs.contains(clip.id) {
                badge(systemImage: "questionmark.folder.fill", color: .red, help: "Datei fehlt")
            } else if clip.meta.needsConversion {
                badge(systemImage: "arrow.triangle.2.circlepath", color: .orange, help: "Arbeitskopie nötig")
            } else if clip.hasWarnings {
                badge(
                    systemImage: "exclamationmark.triangle.fill", color: .orange,
                    help: clip.meta.warnings.joined(separator: "\n"))
            }
            if let index = project.story.chapters.firstIndex(where: { $0.id == clip.chapterID }) {
                Circle().fill(Color(nsColor: ChapterPalette.color(project.story.chapters[index].color)))
                    .frame(width: 8, height: 8).padding(3).background(.thinMaterial, in: Circle())
                    .help("Kapitel: \(project.story.chapters[index].name)")
            }
            if let time = StoryResolver.value(.timeOfDay, for: clip, in: project) {
                badge(
                    systemImage: TimeOfDaySymbol.name(time.value), color: .secondary,
                    help: "Tageszeit: \(time.value) (\(TimeOfDaySymbol.source(time.source)))")
            }
            if !clip.blocked.isEmpty {
                badge("⊘\(clip.blocked.count)", help: "\(clip.blocked.count) Sperrbereich(e): werden nie verwendet")
                    .accessibilityIdentifier("library.badge.blocked")
            }
            if clip.excluded { badge(systemImage: "nosign", color: .secondary, help: "Wird nie verwendet") }
        }
    }

    private func badge(_ text: String, help: String) -> some View {
        Text(text).font(.caption2.bold()).padding(.horizontal, 4).padding(.vertical, 1)
            .background(.thinMaterial, in: Capsule()).help(help)
    }

    private func badge(systemImage: String, color: Color, help: String) -> some View {
        Image(systemName: systemImage).font(.caption2).foregroundStyle(color).padding(3)
            .background(.thinMaterial, in: Circle()).help(help)
    }
}

/// Leerer Zustand mit großer Ablagefläche.
struct DropHint: View {
    var title: String
    var systemImage: String
    var detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 34)).foregroundStyle(.tint)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(.tertiary)
                .padding(12)
        }
    }
}
