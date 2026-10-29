import SwiftUI
import SyllaBeatCore
import SyllaBeatUI

/// Vorschau im Timeline-Format mit Song-Wiedergabe und der aktuellen Textzeile. Das Bild (Komposition) folgt in M4.
struct PreviewPane: View {
    var project: Project
    var playback: Playback

    private var aspect: CGFloat {
        CGFloat(project.timeline.width) / CGFloat(max(project.timeline.height, 1))
    }

    private var currentLine: LyricLine? {
        let time = playback.time
        return project.analysis?.lines.first { $0.start - 0.2 <= time && time <= $0.end + 0.4 }
    }

    private var currentSection: SongSection? {
        project.analysis?.sections.first { $0.start <= playback.time && playback.time < $0.end }
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
                        Image(systemName: playback.isPlaying ? "waveform" : "play.rectangle").font(.system(size: 40))
                        if let section = currentSection {
                            Text(section.label).font(.headline)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.55))
                }
                if let line = currentLine {
                    VStack {
                        Spacer()
                        Text(line.text)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .shadow(radius: 3)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 18)
                            .padding(.horizontal, 20)
                            .accessibilityIdentifier("preview.lyrics")
                    }
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Vorschau")

            Divider()
            HStack(spacing: 14) {
                Button(
                    playback.isPlaying ? "Anhalten" : "Abspielen",
                    systemImage: playback.isPlaying ? "pause.fill" : "play.fill"
                ) {
                    playback.toggle()
                }
                .keyboardShortcut(.space, modifiers: [])
                .help("Abspielen oder anhalten (Leertaste)")
                .disabled(!playback.isReady)
                .accessibilityIdentifier("preview.play")
                Button("Zum Anfang", systemImage: "backward.end.fill") { playback.seek(to: 0) }
                    .disabled(!playback.isReady)
                Text("\(Format.time(playback.time)) / \(Format.time(project.analysis?.duration ?? 0))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("preview.time")
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.background)
    }
}
