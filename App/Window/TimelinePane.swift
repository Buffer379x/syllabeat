import AppKit
import SwiftUI
import SyllaBeatAudio
import SyllaBeatCore
import SyllaBeatUI

/// Timeline: Werkzeugleiste für das Raster und darunter vier Spuren mit Zoom, Abspielposition und Bearbeitung.
struct TimelinePane: View {
    var project: Project
    var song: SongController
    var cut: CutController
    var run: (any EditCommand) -> Void
    /// Pixel je Sekunde; `nil` heißt: ganzer Song passt in die Breite.
    @State private var zoom: Double?
    @State private var width: CGFloat = 800
    /// Vorschaubilder der Bildspur nach Pfad im Zwischenspeicher.
    @State private var thumbnails: [String: NSImage] = [:]

    private static let headerWidth: CGFloat = 92

    var body: some View {
        VStack(spacing: 0) {
            if let analysis = project.analysis {
                toolbar(analysis)
                Divider()
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(TimelineCanvas.Track.allCases, id: \.rawValue) { track in
                            Text(track.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: Self.headerWidth, height: track.height, alignment: .leading)
                                .padding(.leading, 10)
                                .overlay(alignment: .bottom) { Divider() }
                        }
                    }
                    Divider()
                    GeometryReader { geometry in
                        TimelineScrollView(
                            content: content(analysis), pixelsPerSecond: pixelsPerSecond(analysis),
                            playhead: song.playback.time, following: song.playback.isPlaying,
                            selection: cut.selection, thumbnails: thumbnails,
                            actions: TimelineActions(
                                seek: { song.playback.seek(to: $0) }, run: run,
                                zoom: { value, _ in zoom = clamp(value, analysis) },
                                select: { cut.selection = $0 })
                        )
                        .onAppear { width = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, new in width = new }
                    }
                }
                .frame(height: TimelineCanvas.totalHeight + 14)
            } else {
                placeholder
            }
        }
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline")
        .task(id: thumbnailPaths) { await loadThumbnails() }
    }

    private var thumbnailPaths: [String] {
        Array(Set((project.cut?.shots ?? []).compactMap { thumbnailURL($0)?.path })).sorted()
    }

    private func thumbnailURL(_ shot: Shot) -> URL? {
        guard let clip = project.clip(withID: shot.clipID) else { return nil }
        return clip.thumbnailURL(scene: clip.scenes.first { $0.id == shot.sceneID })
    }

    private func loadThumbnails() async {
        for path in thumbnailPaths where thumbnails[path] == nil {
            guard !Task.isCancelled else { return }
            if let image = await ThumbnailStore.shared.image(URL(fileURLWithPath: path)) { thumbnails[path] = image }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            if project.song == nil {
                Text("Die Timeline erscheint, sobald ein Song im Projekt ist.")
            } else if song.analyzing {
                ProgressView().controlSize(.small)
                Text("Song wird analysiert …")
            } else {
                Text("Der Song ist noch nicht analysiert.")
                Button("Song analysieren") { song.analyze() }
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toolbar(_ analysis: SongAnalysis) -> some View {
        HStack(spacing: 10) {
            Text("\(analysis.tempo.formatted(.number.precision(.fractionLength(1)))) BPM")
                .monospacedDigit()
                .help("Erkanntes Tempo")
            Menu("Tempo") {
                ForEach(ScaleTempo.Factor.allCases, id: \.rawValue) { factor in
                    Button(factor.title) { run(ScaleTempo(factor: factor)) }
                }
            }
            .fixedSize()
            .help("Tempo korrigieren: verdoppeln, halbieren oder Triolengefühl (×¾, ×4⁄3)")
            Menu("\(analysis.meter)/4") {
                ForEach([3, 4, 6], id: \.self) { meter in
                    Button("\(meter)/4") { run(SetMeter(meter: meter)) }
                }
            }
            .fixedSize()
            .help("Taktart")
            HStack(spacing: 2) {
                Button("−10 ms") { run(ShiftBeats(milliseconds: -10)) }
                Button("+10 ms") { run(ShiftBeats(milliseconds: 10)) }
            }
            .labelStyle(.titleOnly)
            .help("Raster verschieben (jeder Schritt lässt sich rückgängig machen)")
            Text("Rechtsklick auf Beat, Abschnitt oder Wort für mehr").font(.caption).foregroundStyle(.tertiary)
            Spacer()
            if song.transcribing {
                ProgressView().controlSize(.small)
                Text("Gesang wird erkannt …").font(.caption).foregroundStyle(.secondary)
            }
            Button("Verkleinern", systemImage: "minus.magnifyingglass") {
                zoom = clamp(pixelsPerSecond(analysis) / 1.5, analysis)
            }
            .keyboardShortcut("-", modifiers: .command)
            Button("Alles zeigen", systemImage: "arrow.left.and.right") { zoom = nil }
                .keyboardShortcut("0", modifiers: .command)
            Button("Vergrößern", systemImage: "plus.magnifyingglass") {
                zoom = clamp(pixelsPerSecond(analysis) * 1.5, analysis)
            }
            .keyboardShortcut("+", modifiers: .command)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func fit(_ analysis: SongAnalysis) -> Double {
        Double(max(200, width - 4)) / max(1, analysis.duration)
    }

    private func pixelsPerSecond(_ analysis: SongAnalysis) -> Double {
        zoom ?? fit(analysis)
    }

    private func clamp(_ value: Double, _ analysis: SongAnalysis) -> Double? {
        let minimum = fit(analysis)
        let result = min(800, max(minimum, value))
        return result <= minimum * 1.001 ? nil : result
    }

    private func content(_ analysis: SongAnalysis) -> TimelineContent {
        let shots = (project.cut?.shots ?? []).map { shot in
            TimelineShot(
                id: shot.id, start: shot.start.time, end: shot.end.time,
                name: project.clip(withID: shot.clipID)?.name ?? shot.clipID, locked: shot.locked,
                copied: shot.reasons?.copiedFrom != nil, thumbnailKey: thumbnailURL(shot)?.path)
        }
        return TimelineContent(
            duration: analysis.duration, beats: analysis.beats, meter: analysis.meter, sections: analysis.sections,
            words: analysis.words, lines: analysis.lines, shots: shots, waveform: song.waveform)
    }
}

/// Horizontale Bildlaufansicht mit der Zeichenfläche; folgt beim Abspielen der Abspielposition.
struct TimelineScrollView: NSViewRepresentable {
    var content: TimelineContent
    var pixelsPerSecond: Double
    var playhead: Double
    var following: Bool
    var selection: Set<String>
    var thumbnails: [String: NSImage]
    var actions: TimelineActions

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.documentView = TimelineCanvas()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? TimelineCanvas else { return }
        let oldScale = canvas.pixelsPerSecond
        let visibleTime = canvas.time(scroll.contentView.bounds.midX)
        canvas.actions = actions
        canvas.content = content
        canvas.pixelsPerSecond = pixelsPerSecond
        canvas.playhead = playhead
        canvas.selectedShotIDs = selection
        canvas.thumbnails = thumbnails
        let width = max(scroll.contentSize.width, CGFloat(content.duration * pixelsPerSecond))
        if canvas.frame.size != NSSize(width: width, height: TimelineCanvas.totalHeight) {
            canvas.frame = NSRect(x: 0, y: 0, width: width, height: TimelineCanvas.totalHeight)
            canvas.window?.invalidateCursorRects(for: canvas)
        }
        let visible = scroll.contentView.bounds
        if oldScale != pixelsPerSecond {
            // Beim Zoomen bleibt die Mitte (bzw. beim Abspielen die Abspielposition) stehen.
            let target = canvas.x(following ? playhead : visibleTime) - visible.width / 2
            scroll.contentView.scroll(to: NSPoint(x: max(0, min(width - visible.width, target)), y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else if following {
            let x = canvas.x(playhead)
            if x < visible.minX || x > visible.maxX - 40 {
                scroll.contentView.scroll(to: NSPoint(x: max(0, min(width - visible.width, x - 40)), y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }
}
