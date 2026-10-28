import SwiftUI
import SyllaBeatCore

/// Bibliothek: alle Clips mit Kurzdaten und Hinweisen. Suche filtert vorerst nach Name, Beschreibung und Schlagwort.
struct LibraryPane: View {
    var clips: [Clip]
    @Binding var selection: String?
    @State private var query = ""

    private var filtered: [Clip] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return clips }
        return clips.filter { clip in
            let haystack = ([clip.name, clip.description] + clip.tags).joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if clips.isEmpty {
                DropHint(
                    title: "Clips oder Ordner hierher ziehen", systemImage: "film.stack",
                    detail: "Videos werden importiert und in Szenen zerlegt.")
            } else {
                TextField("Suchen", text: $query, prompt: Text("Name, Beschreibung, Schlagwort"))
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                    .accessibilityIdentifier("library.search")
                List(filtered, selection: $selection) { clip in
                    ClipRow(clip: clip).tag(clip.id)
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("library.list")
                Divider()
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .background(.background)
    }

    private var footer: String {
        let total = clips.reduce(0) { $0 + $1.meta.duration }
        let shown =
            filtered.count == clips.count ? "\(clips.count) Clips" : "\(filtered.count) von \(clips.count) Clips"
        return "\(shown) · \(Format.time(total)) Material"
    }
}

private struct ClipRow: View {
    var clip: Clip

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 56, height: 32)
                .overlay { Image(systemName: "film").foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(clip.excluded)
                Text(info).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
            if clip.excluded {
                Image(systemName: "nosign").foregroundStyle(.secondary).help("Wird nie verwendet")
            }
            if !clip.meta.warnings.isEmpty || clip.meta.isVFR == true {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help(clip.meta.warnings.joined(separator: "\n"))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("clip.\(clip.id)")
    }

    private var info: String {
        let scenes = clip.scenes.count == 1 ? "1 Szene" : "\(clip.scenes.count) Szenen"
        return "\(Format.duration(clip.meta.duration)) · \(Format.fps(clip.meta.fps)) fps · \(scenes)"
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
