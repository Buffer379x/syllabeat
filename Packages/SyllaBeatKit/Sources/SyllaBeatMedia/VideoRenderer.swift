import AVFoundation
import CoreImage
import Foundation
import ImageIO
import SyllaBeatCore
import UniformTypeIdentifiers
import VideoToolbox

/// Einstellungen für das fertige Video.
public struct RenderSettings: Sendable, Equatable {
    public enum Codec: String, Sendable, CaseIterable {
        case h264, hevc

        public var title: String {
            switch self {
            case .h264: "H.264"
            case .hevc: "HEVC"
            }
        }
    }

    public var codec: Codec
    /// Liedtext im Bild (Should, noch nicht umgesetzt).
    public var lyrics: Bool

    public init(codec: Codec = .h264, lyrics: Bool = false) {
        self.codec = codec
        self.lyrics = lyrics
    }
}

/// Rendert den Schnitt als MP4 aus derselben Komposition wie die Vorschau (Frame-Tabelle, Song), in Timeline-Format
/// und -Bildrate. Schreibt zuerst in eine temporäre Datei und verschiebt sie am Ende.
@MainActor
public enum VideoRenderer {
    public enum RenderError: Error, LocalizedError, Equatable {
        case missingClips([String])
        case noEncoder(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .missingClips(let ids): "Für das Video fehlen Clips: \(ids.joined(separator: ", "))."
            case .noEncoder(let codec): "Auf diesem Mac steht kein \(codec)-Encoder zur Verfügung."
            case .failed(let reason): "Das Video ließ sich nicht schreiben: \(reason)"
            }
        }
    }

    /// Gibt es einen Hardware-Encoder für den Codec? (Virtuelle Macs im CI haben keinen.)
    public nonisolated static func encoderAvailable(_ codec: RenderSettings.Codec) -> Bool {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let encoders = list as? [[String: Any]] else { return false }
        let type = codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        return encoders.contains { encoder in
            (encoder[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == type
                && (encoder[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool ?? false)
        }
    }

    public static func render(
        table: FrameTable, paths: [String: String], song: String?, fit: TimelineSettings.Fit, settings: RenderSettings,
        to url: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard encoderAvailable(settings.codec) else { throw RenderError.noEncoder(settings.codec.title) }
        let preview = try await PreviewBuilder().build(table: table, paths: paths, song: song, fit: fit)
        guard preview.missing.isEmpty else { throw RenderError.missingClips(preview.missing) }
        try Task.checkCancellation()
        let preset = settings.codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: preview.composition, presetName: preset) else {
            throw RenderError.failed("Exportvorgabe nicht verfügbar")
        }
        session.videoComposition = preview.videoComposition
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let monitor = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let value) = state { progress(value.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        do {
            try await session.export(to: temporary, as: .mp4)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RenderError.failed(error.localizedDescription)
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: temporary, to: url)
        progress(1)
    }

    /// Standbild eines Clips als JPEG (z. B. Vorschaubild für YouTube), eingepasst in `size`.
    public static func writeStill(clipPath: String, at seconds: Double, size: CGSize, to url: URL) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: clipPath)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        guard
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw RenderError.failed("Vorschaubild nicht geschrieben") }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw RenderError.failed("Vorschaubild nicht geschrieben")
        }
    }
}
