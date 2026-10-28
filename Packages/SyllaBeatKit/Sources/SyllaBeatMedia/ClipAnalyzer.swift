import CoreGraphics
import CryptoKit
import Foundation
import SyllaBeatCore

/// Analysiert einen Clip vollständig: Metadaten, Szenen, Keyframes, Vorschaubilder, Filmstreifen, Vision-Merkmale.
/// Bilder landen im Zwischenspeicher, alles andere im zurückgegebenen `Clip`.
public struct ClipAnalyzer: Sendable {
    public var cache: MediaCache
    public var options: SceneDetector.Options

    public init(cache: MediaCache = MediaCache(), options: SceneDetector.Options = SceneDetector.Options()) {
        self.cache = cache
        self.options = options
    }

    /// Stabile Clip-ID aus dem Fingerprint: dieselbe Datei erhält in jedem Projekt dieselbe ID.
    public static func clipID(fingerprint: String) -> String {
        let digest = SHA256.hash(data: Data(fingerprint.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "c-\(digest)"
    }

    public static func mediaRef(for url: URL) throws -> MediaRef {
        MediaRef(
            path: url.path, bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil),
            fingerprint: try Fingerprint.compute(url))
    }

    /// Kurzer erster Schritt für den sofortigen Eintrag in der Bibliothek.
    public func probe(_ url: URL) async throws -> Clip {
        let media = try Self.mediaRef(for: url)
        let id = Self.clipID(fingerprint: media.fingerprint!)
        do {
            let meta = try await MediaProbe.read(url)
            return Clip(id: id, media: media, meta: meta, originalName: url.lastPathComponent)
        } catch MediaError.unsupported {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            let meta = ClipMetadata(
                duration: 0, fps: Rational(25), width: 0, height: 0, sizeBytes: size, needsConversion: true,
                warnings: ["Format nicht direkt lesbar. Eine Arbeitskopie (ffmpeg) macht den Clip nutzbar."])
            return Clip(id: id, media: media, meta: meta, originalName: url.lastPathComponent)
        }
    }

    /// Szenen und Merkmale für einen bereits geprüften Clip.
    public func analyze(_ clip: Clip, progress: @Sendable (Double) -> Void = { _ in }) async throws -> Clip {
        guard !clip.meta.needsConversion, clip.meta.duration > 0 else { return clip }
        let url = URL(fileURLWithPath: clip.media.path)
        let fingerprint = try clip.media.fingerprint ?? Fingerprint.compute(url)
        let folder = try cache.prepare(fingerprint: fingerprint)
        let scan = try await SceneDetector.scan(url, options: options)
        progress(0.6)
        var scenes = SceneDetector.scenes(cuts: scan.cuts, duration: clip.meta.duration, clipID: clip.id)
        let keyframes = scenes.map { SceneDetector.keyframeTime(for: $0, samples: scan.samples) }
        let images = try await Imaging.frames(of: url, at: keyframes)
        progress(0.8)
        for index in scenes.indices {
            let scene = scenes[index]
            let samples = scan.samples.filter { $0.time >= scene.start && $0.time < scene.end }
            let keyframe = keyframes[index]
            scenes[index].keyframeTime = keyframe
            var features = SceneFeatures(
                sharpness: samples.min { abs($0.time - keyframe) < abs($1.time - keyframe) }?.sharpness ?? 0,
                brightness: samples.isEmpty ? 0 : samples.map(\.brightness).reduce(0, +) / Double(samples.count),
                motion: samples.count < 2
                    ? 0 : samples.dropFirst().map(\.motion).reduce(0, +) / Double(samples.count - 1))
            if let image = images[keyframe] {
                try Imaging.writeHEIC(image, to: cache.thumbnail(fingerprint: fingerprint, sceneStart: scene.start))
                let vision = await VisionFeatures.analyze(image)
                features.aesthetics = vision.aesthetics
                features.isUtility = vision.isUtility
                features.labels = vision.labels
                features.faceCount = vision.faceCount
                features.shotSize = ShotSize(largestFaceArea: vision.largestFaceArea)
                features.colors = Imaging.dominantColors(image)
            }
            scenes[index].features = features
            try Task.checkCancellation()
        }
        if let strip = Imaging.strip(scan.filmstrip) {
            try Imaging.writeHEIC(strip, to: cache.filmstrip(fingerprint: fingerprint))
        }
        _ = folder
        progress(1)
        var result = clip
        result.scenes = scenes
        return clip.mergingAnalysis(result)
    }
}
