import AVFoundation
import AppKit
import Observation
import SwiftUI
import SyllaBeatCore
import SyllaBeatUI

/// Wiedergabe eines einzelnen Clips zum Sichten: eigener Player neben der Schnitt-Wiedergabe, Markierung mit I/O.
@MainActor
@Observable
final class ClipPlayer {
    private(set) var time: Double = 0
    private(set) var isPlaying = false
    var markIn: Double?
    var markOut: Double?
    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private(set) var path: String?

    init() {
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = time.seconds
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    func load(_ path: String) {
        guard path != self.path else { return }
        self.path = path
        player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: path)))
        time = 0
        markIn = nil
        markOut = nil
    }

    func toggle() {
        if player.rate != 0 { player.pause() } else { player.play() }
        isPlaying = player.rate != 0
    }

    /// −1 rückwärts, 0 anhalten, +1 vorwärts (J/K/L).
    func transport(_ direction: Int) {
        switch direction {
        case 0: player.pause()
        case let forward where forward > 0: player.rate = player.rate >= 1 ? min(4, player.rate * 2) : 1
        default:
            if player.currentItem?.canPlayReverse ?? false {
                player.rate = player.rate <= -1 ? max(-4, player.rate * 2) : -1
            }
        }
        isPlaying = player.rate != 0
    }

    func seek(_ seconds: Double) {
        time = max(0, seconds)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Bereich zum Sperren: I/O-Markierung oder ±0,5 s um die Abspielposition.
    func rangeToBlock(length: Double) -> SourceRange {
        if let markIn, let markOut, markOut > markIn { return SourceRange(start: markIn, end: markOut) }
        if let markIn, markIn < time { return SourceRange(start: markIn, end: time) }
        return SourceRange(start: max(0, time - 0.5), end: min(length, time + 0.5))
    }
}

/// Clip-Ansicht in der Vorschau: Clip abspielen, Fehlerstellen markieren und sperren, zum nächsten Clip springen.
struct ClipViewer: View {
    var clip: Clip
    var player: ClipPlayer
    var run: (any EditCommand) -> Void
    var step: (Int) -> Void
    var close: () -> Void
    @FocusState private var focused: Bool

    private var length: Double { clip.meta.availableSeconds.doubleValue }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Clip: \(clip.name)", systemImage: "film").font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Button("Zurück zum Schnitt", systemImage: "xmark", action: close)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("clipviewer.close")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            ZStack {
                Rectangle().fill(.black)
                ClipPlayerLayer(player: player.player).accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            RangeBar(clip: clip, player: player)
                .frame(height: 30)
                .padding(.horizontal, 10).padding(.top, 6)
                .accessibilityIdentifier("clipviewer.rangebar")
            HStack(spacing: 12) {
                Button("Sperren", systemImage: "nosign") { block() }.accessibilityIdentifier("clipviewer.block")
                Text("I Anfang · O Ende · X sperren · ⌥X Sperre entfernen · ↑↓ Clip · J K L · Leertaste")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Format.time(player.time)) / \(Format.time(length))").monospacedDigit().font(.callout)
            }
            .controlSize(.small)
            .padding(10)
        }
        .background(.background)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            player.load(clip.media.path)
            focused = true
        }
        .onChange(of: clip.id) { _, _ in player.load(clip.media.path) }
        .onKeyPress(phases: .down) { press in handle(press) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipviewer")
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch (press.key, press.modifiers) {
        case (.space, []): player.toggle()
        case (.upArrow, []): step(-1)
        case (.downArrow, []): step(1)
        case (.leftArrow, []): player.seek(max(0, player.time - 1 / clip.meta.fps.doubleValue))
        case (.rightArrow, []): player.seek(min(length, player.time + 1 / clip.meta.fps.doubleValue))
        default:
            switch (press.characters.lowercased(), press.modifiers) {
            case ("i", []): player.markIn = player.time
            case ("o", []): player.markOut = player.time
            case ("x", []): block()
            case ("x", .option), ("≈", .option): unblock()
            case ("j", []): player.transport(-1)
            case ("k", []): player.transport(0)
            case ("l", []): player.transport(1)
            default: return .ignored
            }
        }
        return .handled
    }

    private func block() {
        run(SetBlockedRanges(clipID: clip.id, ranges: clip.blocked + [player.rangeToBlock(length: length)]))
        player.markIn = nil
        player.markOut = nil
    }

    /// Sperre an der Abspielposition entfernen.
    private func unblock() {
        let time = player.time
        let remaining = clip.blocked.filter { !($0.start <= time && time <= $0.end) }
        guard remaining.count != clip.blocked.count else { return }
        run(SetBlockedRanges(clipID: clip.id, ranges: remaining))
    }
}

/// Zeitleiste des Clips: Szenen, Sperrbereiche (rot schraffiert), Markierung (blau), Abspielposition.
private struct RangeBar: View {
    var clip: Clip
    var player: ClipPlayer

    private var length: Double { max(clip.meta.availableSeconds.doubleValue, 0.001) }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Canvas { context, size in
                func x(_ t: Double) -> CGFloat { CGFloat(t / length) * size.width }
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(0.15)))
                for scene in clip.scenes where scene.start > 0 && !scene.continuesPrevious {
                    context.fill(
                        Path(CGRect(x: x(scene.start), y: 0, width: 1, height: size.height)), with: .color(.secondary))
                }
                for range in clip.blocked {
                    let rect = CGRect(
                        x: x(range.start), y: 0, width: max(2, x(range.end) - x(range.start)), height: size.height)
                    context.fill(Path(rect), with: .color(.red.opacity(0.35)))
                    var stripes = Path()
                    var offset = rect.minX - size.height
                    while offset < rect.maxX {
                        stripes.move(to: CGPoint(x: offset, y: size.height))
                        stripes.addLine(to: CGPoint(x: offset + size.height, y: 0))
                        offset += 6
                    }
                    var hatched = context
                    hatched.clip(to: Path(rect))
                    hatched.stroke(stripes, with: .color(.red), lineWidth: 1)
                }
                if let markIn = player.markIn {
                    let end = player.markOut ?? player.time
                    let rect = CGRect(x: x(min(markIn, end)), y: 0, width: abs(x(end) - x(markIn)), height: size.height)
                    context.fill(Path(rect), with: .color(.blue.opacity(0.3)))
                }
                context.fill(
                    Path(CGRect(x: x(player.time) - 1, y: 0, width: 2, height: size.height)), with: .color(.accentColor)
                )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = Double(value.startLocation.x / width) * length
                        let now = Double(value.location.x / width) * length
                        if abs(value.translation.width) < 3 {
                            player.seek(min(length, max(0, now)))
                        } else {
                            player.markIn = min(length, max(0, min(start, now)))
                            player.markOut = min(length, max(0, max(start, now)))
                        }
                    })
        }
        .accessibilityLabel("Clip-Zeitleiste mit \(clip.blocked.count) Sperrbereichen")
    }
}

/// AVPlayerLayer für den Clip.
private struct ClipPlayerLayer: NSViewRepresentable {
    var player: AVPlayer

    final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
        }
        required init?(coder: NSCoder) { nil }
        override func makeBackingLayer() -> CALayer { playerLayer }
    }

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) { view.playerLayer.player = player }
}
