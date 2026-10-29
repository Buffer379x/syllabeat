import SwiftUI
import SyllaBeatCore
import SyllaBeatUI

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, unused, used, favorites, warnings, excluded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Alle Clips"
        case .unused: "Unbenutzt"
        case .used: "Im Schnitt"
        case .favorites: "Favoriten"
        case .warnings: "Mit Hinweisen"
        case .excluded: "Nie verwenden"
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
    @Binding var selection: String?
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

    private func grid(_ clips: [Clip]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 220), spacing: 8)], spacing: 10) {
                ForEach(clips) { clip in
                    ClipTile(clip: clip, project: project, media: media, selected: selection == clip.id)
                        .onTapGesture { selection = clip.id }
                        .accessibilityAddTraits(selection == clip.id ? [.isSelected, .isButton] : .isButton)
                }
            }
            .padding(8)
        }
        .accessibilityIdentifier("library.grid")
    }

    private func list(_ clips: [Clip]) -> some View {
        List(clips, selection: $selection) { clip in
            ClipRow(clip: clip, project: project, media: media).tag(clip.id)
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
        .accessibilityLabel("\(clip.name), \(Format.duration(clip.meta.duration))")
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
