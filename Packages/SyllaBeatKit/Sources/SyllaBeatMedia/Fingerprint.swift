import CryptoKit
import Foundation

/// Identität einer Mediendatei über Umbenennen und Kopieren hinweg, kompatibel zu 0.2.0:
/// `<Größe>:<SHA-256 der ersten 128 KiB und der letzten 128 KiB>`.
public enum Fingerprint {
    static let chunk = 131_072

    public static func compute(_ url: URL) throws -> String {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        hasher.update(data: try handle.read(upToCount: chunk) ?? Data())
        if size > Int64(chunk) {
            try handle.seek(toOffset: UInt64(max(Int64(chunk), size - Int64(chunk))))
            hasher.update(data: try handle.read(upToCount: chunk) ?? Data())
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(size):\(digest)"
    }
}
