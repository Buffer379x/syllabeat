import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Vorschaubilder aus Videos und HEIC-Dateien im Zwischenspeicher.
public enum Imaging {
    /// Bilder zu den angegebenen Zeiten, längste Kante `maximumSize`, mit angewandter Drehung.
    public static func frames(of url: URL, at times: [Double], maximumSize: Int = 320) async throws -> [Double: CGImage]
    {
        guard !times.isEmpty else { return [:] }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumSize, height: maximumSize)
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var result: [Double: CGImage] = [:]
        let requested = times.map { CMTime(seconds: $0, preferredTimescale: 600) }
        for await item in generator.images(for: requested) {
            try Task.checkCancellation()
            if case .success(let requestedTime, let image, _) = item {
                let key = times.min { abs($0 - requestedTime.seconds) < abs($1 - requestedTime.seconds) }!
                result[key] = image
            }
        }
        return result
    }

    public static func writeHEIC(_ image: CGImage, to url: URL, quality: Double = 0.7) throws {
        let type = UTType.heic.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    public static func read(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Setzt Bilder gleicher Höhe nebeneinander (Filmstreifen).
    public static func strip(_ images: [CGImage]) -> CGImage? {
        guard let first = images.first else { return nil }
        let height = first.height
        let widths = images.map { $0.width * height / max($0.height, 1) }
        guard
            let context = CGContext(
                data: nil, width: widths.reduce(0, +), height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        var x = 0
        for (image, width) in zip(images, widths) {
            context.draw(image, in: CGRect(x: x, y: 0, width: width, height: height))
            x += width
        }
        return context.makeImage()
    }

    /// Bis zu drei dominante Farben als `#RRGGBB` (grobe Quantisierung auf 4 Stufen je Kanal).
    public static func dominantColors(_ image: CGImage, count: Int = 3) -> [String] {
        let size = 32
        guard
            let context = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var buckets: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for i in 0..<(size * size) {
            let r = Int(data[4 * i])
            let g = Int(data[4 * i + 1])
            let b = Int(data[4 * i + 2])
            let key = (r >> 6) << 4 | (g >> 6) << 2 | (b >> 6)
            let old = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (old.count + 1, old.r + r, old.g + g, old.b + b)
        }
        return buckets.values.sorted { $0.count > $1.count }.prefix(count).map { bucket in
            String(format: "#%02X%02X%02X", bucket.r / bucket.count, bucket.g / bucket.count, bucket.b / bucket.count)
        }
    }
}
