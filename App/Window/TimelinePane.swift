import SwiftUI
import SyllaBeatCore

/// Vorläufige Timeline: vier Spuren über die volle Songlänge, ohne Zoom und Bearbeitung (folgt in M3).
struct TimelinePane: View {
    var project: Project

    private static let headerWidth: CGFloat = 92

    var body: some View {
        VStack(spacing: 0) {
            if let analysis = project.analysis {
                track("Abschnitte", height: 30) { SectionTrack(analysis: analysis) }
                track("Text", height: 26) { LyricsTrack(analysis: analysis) }
                track("Song", height: 64) { BeatTrack(analysis: analysis) }
                track("Bild", height: 52) { ShotTrack(project: project, duration: analysis.duration) }
                Spacer(minLength: 0)
            } else {
                Text(
                    project.song == nil
                        ? "Die Timeline erscheint, sobald ein Song im Projekt ist."
                        : "Die Timeline erscheint nach der Songanalyse."
                )
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline")
    }

    private func track(_ title: String, height: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: Self.headerWidth, alignment: .leading)
                .padding(.leading, 10)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .frame(height: height)
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension SongSection.Kind {
    var color: Color {
        switch self {
        case .verse: .blue
        case .preChorus: .purple
        case .chorus: .mint
        case .bridge: .pink
        case .intro, .outro: .gray
        case .instrumental: .teal
        case .other: .secondary
        }
    }
}

private struct SectionTrack: View {
    var analysis: SongAnalysis

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / max(analysis.duration, 0.001)
            ForEach(analysis.sections) { section in
                let width = max(1, (section.end - section.start) * scale - 1)
                RoundedRectangle(cornerRadius: 3)
                    .fill(section.kind.color.opacity(0.35))
                    .overlay(alignment: .leading) {
                        Text(section.repeatOf == nil ? section.label : "\(section.label) ●")
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                    }
                    .frame(width: width, height: geometry.size.height - 6)
                    .offset(x: section.start * scale, y: 3)
                    .help("\(section.label): \(Format.time(section.start)) – \(Format.time(section.end))")
            }
        }
    }
}

private struct LyricsTrack: View {
    var analysis: SongAnalysis

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / max(analysis.duration, 0.001)
            ForEach(analysis.lines) { line in
                Text(line.text)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(line.needsReview ? .orange : .primary)
                    .frame(width: max(1, (line.end - line.start) * scale), alignment: .leading)
                    .offset(x: line.start * scale, y: (geometry.size.height - 14) / 2)
            }
        }
    }
}

private struct BeatTrack: View {
    var analysis: SongAnalysis

    var body: some View {
        Canvas { context, size in
            let scale = size.width / max(analysis.duration, 0.001)
            for (index, beat) in analysis.beats.enumerated() {
                let x = beat.time * scale
                let bar = beat.isDownbeat || index % analysis.meter == 0
                let height = bar ? size.height * 0.8 : size.height * 0.45
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: bar ? 1.5 : 1, height: height)
                context.fill(Path(rect), with: .color(bar ? .primary.opacity(0.7) : .secondary.opacity(0.5)))
            }
        }
        .accessibilityLabel("\(analysis.beats.count) Beats")
        .accessibilityIdentifier("timeline.beats")
    }
}

private struct ShotTrack: View {
    var project: Project
    var duration: Double

    var body: some View {
        if let cut = project.cut {
            GeometryReader { geometry in
                let scale = geometry.size.width / max(duration, 0.001)
                ForEach(Array(cut.shots.enumerated()), id: \.element.id) { index, shot in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            index.isMultiple(of: 2) ? Color.accentColor.opacity(0.45) : Color.accentColor.opacity(0.25)
                        )
                        .frame(
                            width: max(1, (shot.end.time - shot.start.time) * scale - 1),
                            height: geometry.size.height - 8
                        )
                        .offset(x: shot.start.time * scale, y: 4)
                        .help(
                            "\(project.clip(withID: shot.clipID)?.name ?? shot.clipID): \(Format.time(shot.start.time)) – \(Format.time(shot.end.time))"
                        )
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(cut.shots.count) Einstellungen")
            .accessibilityIdentifier("timeline.shots")
        } else {
            Text("Noch kein Schnitt").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
