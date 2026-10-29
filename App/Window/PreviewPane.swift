import AVFoundation
import AppKit
import SwiftUI
import SyllaBeatCore
import SyllaBeatUI

/// Vorschau im Timeline-Format: der Schnitt synchron zum Song (eine Komposition, Bild und Ton aus einer Uhr) mit der
/// aktuellen Textzeile darüber. Ohne Schnitt läuft nur der Song.
struct PreviewPane: View {
    var project: Project
    var playback: Playback
    var cut: CutController

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

    private var shotStarts: [Double] { project.cut?.shots.map(\.start.time) ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(.black)
                if playback.hasVideo {
                    PlayerLayerView(player: playback.player)
                        .accessibilityHidden(true)
                } else if project.song == nil && project.clips.isEmpty {
                    DropHint(
                        title: "Song hierher ziehen", systemImage: "music.note",
                        detail: "Danach Clips links ablegen. Der erste Schnitt entsteht automatisch."
                    )
                    .environment(\.colorScheme, .dark)
                } else {
                    placeholder
                }
                if let line = currentLine {
                    VStack {
                        Spacer()
                        Text(line.text)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.8), radius: 3)
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
            .accessibilityLabel(playback.hasVideo ? "Vorschau des Schnitts" : "Vorschau")
            .accessibilityIdentifier("preview.video")

            Divider()
            controls
        }
        .background(.background)
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 8) {
            if cut.generating {
                ProgressView().controlSize(.small).environment(\.colorScheme, .dark)
                Text("Erster Schnitt entsteht …")
            } else if let problem = cut.previewProblem {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 30))
                Text(problem).multilineTextAlignment(.center).padding(.horizontal, 30)
                if cut.canCut {
                    Button("Neu schneiden") { cut.generate() }
                        .environment(\.colorScheme, .dark)
                }
            } else {
                Image(systemName: playback.isPlaying ? "waveform" : "play.rectangle").font(.system(size: 40))
                if let section = currentSection { Text(section.label).font(.headline) }
            }
        }
        .foregroundStyle(.white.opacity(0.6))
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button("Vorige Einstellung", systemImage: "backward.end.fill") {
                let previous = shotStarts.last { $0 < playback.time - 0.05 } ?? 0
                playback.seek(to: previous)
            }
            .disabled(!playback.isReady)
            .help("Zum Anfang der vorigen Einstellung")
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
            Button("Nächste Einstellung", systemImage: "forward.end.fill") {
                if let next = shotStarts.first(where: { $0 > playback.time + 0.01 }) { playback.seek(to: next) }
            }
            .disabled(!playback.isReady || shotStarts.isEmpty)
            .help("Zum Anfang der nächsten Einstellung")
            Text("\(Format.time(playback.time)) / \(Format.time(project.analysis?.duration ?? 0))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("preview.time")
            Spacer()
            if !cut.previewMissing.isEmpty {
                Label("\(cut.previewMissing.count) Clips fehlen", systemImage: "questionmark.folder")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Diese Einstellungen bleiben schwarz. „Ablage → Medien neu verknüpfen …“ sucht die Dateien.")
            }
            Menu {
                Picker(
                    "Bildanpassung",
                    selection: Binding(
                        get: { project.timeline.fit }, set: { cut.run(SetFit(fit: $0)) })
                ) {
                    ForEach(TimelineSettings.Fit.allCases, id: \.rawValue) { fit in Text(fit.title).tag(fit) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(project.timeline.fit.title, systemImage: "rectangle.dashed")
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Clips mit anderem Seitenverhältnis füllen das Bild (Ränder beschnitten) oder werden eingepasst")
            .accessibilityIdentifier("preview.fit")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// AVPlayerLayer als Ansicht. Das Bild hat schon das Timeline-Format, deshalb nur einpassen.
struct PlayerLayerView: NSViewRepresentable {
    var player: AVPlayer

    final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

        override func makeBackingLayer() -> CALayer { playerLayer }
    }

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
