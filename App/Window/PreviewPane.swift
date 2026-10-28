import SwiftUI
import SyllaBeatCore

/// Platzhalter der Vorschau im Timeline-Format. Der Player mit Komposition folgt in M3/M4.
struct PreviewPane: View {
    var project: Project

    private var aspect: CGFloat {
        CGFloat(project.timeline.width) / CGFloat(max(project.timeline.height, 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(.black)
                if project.song == nil && project.clips.isEmpty {
                    DropHint(
                        title: "Song hierher ziehen", systemImage: "music.note",
                        detail: "Danach Clips links ablegen. Der erste Schnitt entsteht automatisch."
                    )
                    .environment(\.colorScheme, .dark)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "play.rectangle").font(.system(size: 40))
                        Text("Vorschau").font(.headline)
                    }
                    .foregroundStyle(.white.opacity(0.55))
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Vorschau")

            Divider()
            HStack(spacing: 14) {
                Button("Vorige Einstellung", systemImage: "backward.end.fill", action: {})
                Button("Abspielen (Leertaste)", systemImage: "play.fill", action: {})
                Button("Nächste Einstellung", systemImage: "forward.end.fill", action: {})
                Text("\(Format.time(0)) / \(Format.time(project.analysis?.duration ?? 0))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(true)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.background)
    }
}
