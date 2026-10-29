import AVFoundation
import SyllaBeatCore

/// Vorschau eines Schnitts: Komposition aus der Frame-Tabelle (dieselbe wie für die Exporte) mit dem Song als Ton.
/// Zwei Videospuren wechseln sich ab, damit jeder Shot Format und Drehung seines Clips behält.
@MainActor
public final class PreviewBuilder {
    public struct Preview {
        public var composition: AVComposition
        public var videoComposition: AVVideoComposition
        /// Aufbauzeit in Millisekunden.
        public var milliseconds: Double
        /// Clips, deren Datei fehlt oder nicht lesbar ist (Shots bleiben schwarz).
        public var missing: [String]
    }

    private struct Source {
        var asset: AVURLAsset
        var track: AVAssetTrack
        /// Bildrechteck nach der Drehung (Ursprung 0,0).
        var transform: CGAffineTransform
        var size: CGSize
    }

    /// Geladene Assets je Pfad: Der Neuaufbau nach einer Änderung lädt nichts erneut.
    private var sources: [String: Source] = [:]
    private var unreadable: Set<String> = []
    /// Asset und Tonspur je Song; die Spur taugt nur, solange ihr Asset lebt.
    private var songs: [String: (asset: AVURLAsset, track: AVAssetTrack)] = [:]

    public init() {}

    /// Baut die Komposition. `paths` ordnet Clip-IDs ihre abspielbare Datei zu (Arbeitskopie, falls vorhanden).
    public func build(
        table: FrameTable, paths: [String: String], song: String?, fit: TimelineSettings.Fit
    ) async throws
        -> Preview
    {
        let started = DispatchTime.now().uptimeNanoseconds
        let composition = AVMutableComposition()
        let rate = table.fps
        let total = Self.time(table.durationFrames, rate)
        let render = CGSize(width: table.width, height: table.height)
        var missing: [String] = []

        let lanes = (0..<2).compactMap { _ in
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for (index, entry) in table.entries.enumerated() {
            let start = Self.time(entry.startFrame, rate)
            let duration = Self.time(entry.endFrame, rate) - start
            let range = CMTimeRange(start: start, duration: duration)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = range
            if let path = paths[entry.clipID], let source = await source(path) {
                let lane = lanes[index % lanes.count]
                let laneEnd = lane.timeRange.end
                if laneEnd < start {
                    lane.insertEmptyTimeRange(CMTimeRange(start: laneEnd, end: start))
                }
                let sourceIn = Self.time(entry.sourceInFrame, entry.sourceFPS)
                try lane.insertTimeRange(CMTimeRange(start: sourceIn, duration: duration), of: source.track, at: start)
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: lane)
                layer.setTransform(Self.placement(source, in: render, fit: fit), at: start)
                instruction.layerInstructions = [layer]
            } else {
                missing.append(entry.clipID)
            }
            instructions.append(instruction)
        }
        for lane in lanes where lane.timeRange.end < total {
            lane.insertEmptyTimeRange(CMTimeRange(start: lane.timeRange.end, end: total))
        }
        if let song, let track = await songTrack(song) {
            let audio = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            let available = try await track.load(.timeRange)
            try audio?.insertTimeRange(
                CMTimeRange(start: available.start, duration: min(total, available.duration)), of: track, at: .zero)
        }

        let video = AVMutableVideoComposition()
        video.renderSize = render
        video.frameDuration = CMTime(value: rate.denominator, timescale: CMTimeScale(rate.numerator))
        video.instructions = instructions
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        return Preview(
            composition: composition, videoComposition: video, milliseconds: milliseconds,
            missing: Array(Set(missing)).sorted())
    }

    /// Frame `frame` bei `rate` als exakte CMTime (Zeitbasis = Zähler der Rate).
    nonisolated static func time(_ frame: Int64, _ rate: Rational) -> CMTime {
        CMTime(value: frame * rate.denominator, timescale: CMTimeScale(rate.numerator))
    }

    /// Drehung des Clips, dann Skalieren (Füllen oder Einpassen) und Zentrieren im Renderformat.
    nonisolated static func placement(
        _ size: CGSize, transform: CGAffineTransform, in render: CGSize, fit: TimelineSettings.Fit
    )
        -> CGAffineTransform
    {
        guard size.width > 0, size.height > 0 else { return .identity }
        let scale =
            fit == .fill
            ? max(render.width / size.width, render.height / size.height)
            : min(render.width / size.width, render.height / size.height)
        return
            transform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(
                CGAffineTransform(
                    translationX: (render.width - size.width * scale) / 2,
                    y: (render.height - size.height * scale) / 2))
    }

    private static func placement(_ source: Source, in render: CGSize, fit: TimelineSettings.Fit) -> CGAffineTransform {
        placement(source.size, transform: source.transform, in: render, fit: fit)
    }

    private func source(_ path: String) async -> Source? {
        if let cached = sources[path] { return cached }
        guard !unreadable.contains(path), FileManager.default.fileExists(atPath: path) else { return nil }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                unreadable.insert(path)
                return nil
            }
            let (natural, preferred) = try await track.load(.naturalSize, .preferredTransform)
            // Drehung so verschieben, dass das gedrehte Bild bei 0,0 beginnt.
            let bounds = CGRect(origin: .zero, size: natural).applying(preferred)
            let transform = preferred.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            let source = Source(asset: asset, track: track, transform: transform, size: bounds.size)
            sources[path] = source
            return source
        } catch {
            unreadable.insert(path)
            return nil
        }
    }

    private func songTrack(_ path: String) async -> AVAssetTrack? {
        if let cached = songs[path] { return cached.track }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        songs[path] = (asset, track)
        return track
    }

    /// Nach Neuverknüpfen oder Arbeitskopie: Datei neu laden.
    public func forget(_ path: String) {
        sources[path] = nil
        unreadable.remove(path)
    }
}
