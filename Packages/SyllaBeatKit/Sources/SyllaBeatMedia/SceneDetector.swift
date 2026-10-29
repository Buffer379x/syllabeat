import AVFoundation
import CoreGraphics
import Foundation
import SyllaBeatCore

/// Ergebnis eines Dekodierdurchlaufs: harte Schnitte und Messwerte je Stichprobe.
public struct SceneScan: Sendable {
    public struct Sample: Sendable {
        public var time: Double
        /// Mittlere Helligkeitsdifferenz zur vorherigen Stichprobe, 0…1.
        public var motion: Double
        public var brightness: Double
        /// Laplace-Varianz (Schärfe) auf 160 × 90.
        public var sharpness: Double
    }

    /// Framegenaue Schnittzeitpunkte (Beginn der neuen Einstellung).
    public var cuts: [Double]
    public var samples: [Sample]
    /// Kleine Bilder über die Cliplänge für den Filmstreifen.
    public var filmstrip: [CGImage]
}

/// Szenenerkennung: Hardware-Dekodierung mit verkleinerter Ausgabe (160 × 90), HSV-Histogramm 16 × 8,
/// Bhattacharyya-Abstand, adaptive Schwelle (Median + 8 · MAD, mindestens 0,35). Jeder gefundene Schnitt
/// wird danach in einem kurzen Fenster Frame für Frame verfeinert.
public enum SceneDetector {
    public struct Options: Sendable {
        public var samplesPerSecond = 6.0
        public var width = 160
        public var height = 90
        public var filmstripCount = 10
        public init() {}
    }

    public static func scan(_ url: URL, options: Options = Options()) async throws -> SceneScan {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideo(url.lastPathComponent)
        }
        let fps = Double(try await track.load(.nominalFrameRate))
        let duration = try await asset.load(.duration).seconds
        let objects = Unshared(value: (asset, track))
        return try await Blocking.run { cancellation in
            try scan(
                asset: objects.value.0, track: objects.value.1, name: url.lastPathComponent, fps: fps,
                duration: duration, options: options, cancellation)
        }
    }

    /// Der eigentliche Dekodierdurchlauf; blockiert und läuft daher auf der Lese-Queue.
    private static func scan(
        asset: AVURLAsset, track: AVAssetTrack, name: String, fps: Double, duration: Double, options: Options,
        _ cancellation: Blocking.Cancellation
    ) throws -> SceneScan {
        let reader = try AVAssetReader(asset: asset)
        let output = output(for: track, width: options.width, height: options.height)
        reader.add(output)
        reader.startReading()
        let step = max(1, Int((max(fps, 1) / options.samplesPerSecond).rounded()))
        let slots = (0..<options.filmstripCount).map { duration * (Double($0) + 0.5) / Double(options.filmstripCount) }
        var strip = [(distance: Double, image: CGImage?)](repeating: (.infinity, nil), count: slots.count)
        var index = 0
        var previous: Frame?
        var distances: [(previousTime: Double, time: Double, distance: Double)] = []
        var samples: [SceneScan.Sample] = []
        while let buffer = output.copyNextSampleBuffer() {
            defer { index += 1 }
            try cancellation.check()
            guard index % step == 0, let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            let frame = Frame(pixels, time: time)
            var motion = 0.0
            if let previous {
                distances.append((previous.time, time, frame.histogramDistance(to: previous)))
                motion = frame.lumaDifference(to: previous)
            }
            samples.append(
                SceneScan.Sample(time: time, motion: motion, brightness: frame.brightness, sharpness: frame.sharpness))
            if let slot = slots.indices.min(by: { abs(slots[$0] - time) < abs(slots[$1] - time) }),
                abs(slots[slot] - time) < strip[slot].distance
            {
                strip[slot] = (abs(slots[slot] - time), frame.image(pixels))
            }
            previous = frame
        }
        if reader.status == .failed {
            throw MediaError.unreadable(name, reader.error?.localizedDescription ?? "unbekannt")
        }
        let values = distances.map(\.distance).sorted()
        let median = values.isEmpty ? 0 : values[values.count / 2]
        let mad = values.isEmpty ? 0 : values.map { abs($0 - median) }.sorted()[values.count / 2]
        let threshold = max(0.35, median + 8 * mad)
        var cuts: [Double] = []
        for candidate in distances where candidate.distance > threshold {
            try cancellation.check()
            let refined =
                try refine(asset: asset, track: track, from: candidate.previousTime, to: candidate.time, fps: fps)
                ?? candidate.time
            if let last = cuts.last, refined - last < 0.2 { continue }
            if refined > 0.05, refined < duration - 0.05 { cuts.append(refined) }
        }
        return SceneScan(cuts: cuts, samples: samples, filmstrip: strip.compactMap(\.image))
    }

    /// Sucht zwischen zwei Stichproben den Frame mit dem größten Bildwechsel.
    static func refine(
        asset: AVURLAsset, track: AVAssetTrack, from start: Double, to end: Double, fps: Double
    ) throws -> Double? {
        let frameDuration = 1 / max(fps, 1)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, start - frameDuration / 2), preferredTimescale: 600_000),
            end: CMTime(seconds: end + frameDuration / 2, preferredTimescale: 600_000))
        let output = output(for: track, width: 64, height: 36)
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        var previous: Frame?
        var best: (time: Double, distance: Double)?
        while let buffer = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            let frame = Frame(pixels, time: time)
            if let previous {
                let distance = frame.histogramDistance(to: previous)
                if distance > (best?.distance ?? 0) { best = (time, distance) }
            }
            previous = frame
        }
        return best?.time
    }

    static func output(for track: AVAssetTrack, width: Int, height: Int) -> AVAssetReaderTrackOutput {
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        output.alwaysCopiesSampleData = false
        return output
    }

    /// Teilt einen Clip an den Schnitten in Szenen. Lange Einstellungen werden in gleich lange Teile
    /// (höchstens `maximumLength`) zerlegt, Szenen unter `minimumLength` mit dem Nachbarn verschmolzen.
    public static func scenes(
        cuts: [Double], duration: Double, clipID: String, maximumLength: Double = 5, minimumLength: Double = 0.8
    ) -> [ClipScene] {
        var bounds = [0.0] + cuts.filter { $0 > 0 && $0 < duration }.sorted() + [duration]
        var index = 1
        while index < bounds.count, bounds.count > 2 {
            if bounds[index] - bounds[index - 1] < minimumLength {
                // Kurze Szene: Grenze zum Nachbarn entfernen (am Ende die vorherige).
                bounds.remove(at: index == bounds.count - 1 ? index - 1 : index)
            } else {
                index += 1
            }
        }
        var ranges: [(Double, Double)] = []
        for (start, end) in zip(bounds, bounds.dropFirst()) {
            let length = end - start
            let count = length > maximumLength ? Int((length / maximumLength).rounded(.up)) : 1
            let part = length / Double(count)
            for i in 0..<count {
                ranges.append((start + Double(i) * part, i == count - 1 ? end : start + Double(i + 1) * part))
            }
        }
        return ranges.enumerated().map { number, range in
            ClipScene(id: "\(clipID)-s\(number + 1)", start: range.0, end: range.1)
        }
    }

    /// Keyframe einer Szene: schärfste Stichprobe in ±0,3 s um die Mitte, sonst die Mitte.
    public static func keyframeTime(for scene: ClipScene, samples: [SceneScan.Sample]) -> Double {
        let middle = (scene.start + scene.end) / 2
        let window = min(0.3, scene.duration / 2)
        let candidates = samples.filter {
            abs($0.time - middle) <= window && $0.time >= scene.start && $0.time < scene.end
        }
        return candidates.max { $0.sharpness < $1.sharpness }?.time ?? middle
    }
}

/// Eine verkleinerte Stichprobe mit Histogramm und Helligkeitsraster.
struct Frame {
    var time: Double = 0
    var histogram: [Float]
    /// Helligkeit 0…1 auf einem groben Raster.
    var luma: [Float]
    var width: Int
    var height: Int

    init(_ pixels: CVPixelBuffer, time: Double = 0) {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let w = CVPixelBufferGetWidth(pixels)
        let h = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        var histogram = [Float](repeating: 0, count: 16 * 8)
        var luma = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base + y * stride
            for x in 0..<w {
                let b = Float(row[4 * x]) / 255
                let g = Float(row[4 * x + 1]) / 255
                let r = Float(row[4 * x + 2]) / 255
                let maxV = max(r, g, b)
                let delta = maxV - min(r, g, b)
                var hue: Float = 0
                if delta > 1e-5 {
                    if maxV == r {
                        hue = (g - b) / delta
                    } else if maxV == g {
                        hue = 2 + (b - r) / delta
                    } else {
                        hue = 4 + (r - g) / delta
                    }
                    hue = (hue / 6).truncatingRemainder(dividingBy: 1)
                    if hue < 0 { hue += 1 }
                }
                let saturation = maxV > 0 ? delta / maxV : 0
                histogram[min(15, Int(hue * 16)) * 8 + min(7, Int(saturation * 8))] += 1
                luma[y * w + x] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }
        let count = Float(max(1, w * h))
        self.histogram = histogram.map { $0 / count }
        self.luma = luma
        self.width = w
        self.height = h
        self.time = time
    }

    func histogramDistance(to other: Frame) -> Double {
        var coefficient: Float = 0
        for i in histogram.indices { coefficient += (histogram[i] * other.histogram[i]).squareRoot() }
        return Double(max(0, 1 - coefficient).squareRoot())
    }

    func lumaDifference(to other: Frame) -> Double {
        guard luma.count == other.luma.count, !luma.isEmpty else { return 0 }
        var total: Float = 0
        for i in luma.indices { total += abs(luma[i] - other.luma[i]) }
        return Double(total / Float(luma.count))
    }

    var brightness: Double {
        luma.isEmpty ? 0 : Double(luma.reduce(0, +) / Float(luma.count))
    }

    /// Varianz des Laplace-Operators (4er-Nachbarschaft), skaliert auf 0…255-Helligkeit.
    var sharpness: Double {
        guard width > 2, height > 2 else { return 0 }
        var sum = 0.0
        var squares = 0.0
        var count = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let value = Double(4 * luma[i] - luma[i - 1] - luma[i + 1] - luma[i - width] - luma[i + width]) * 255
                sum += value
                squares += value * value
                count += 1
            }
        }
        let mean = sum / count
        return squares / count - mean * mean
    }

    /// Kopiert die Pixel in ein eigenes Bild; der Decoder verwendet seine Puffer wieder.
    func image(_ pixels: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let w = CVPixelBufferGetWidth(pixels)
        let h = CVPixelBufferGetHeight(pixels)
        let sourceStride = CVPixelBufferGetBytesPerRow(pixels)
        guard let source = CVPixelBufferGetBaseAddress(pixels),
            let context = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            let target = context.data
        else { return nil }
        for y in 0..<h {
            memcpy(target + y * context.bytesPerRow, source + y * sourceStride, w * 4)
        }
        return context.makeImage()
    }
}
