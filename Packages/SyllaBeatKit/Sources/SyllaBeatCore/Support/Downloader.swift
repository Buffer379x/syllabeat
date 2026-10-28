import CryptoKit
import Foundation

/// Eine herunterzuladende Datei mit Prüfsumme.
public struct DownloadItem: Sendable, Equatable {
    public var url: URL
    public var sha256: String
    public var bytes: Int64

    public init(url: URL, sha256: String, bytes: Int64) {
        self.url = url
        self.sha256 = sha256.lowercased()
        self.bytes = bytes
    }

    public var fileName: String { url.lastPathComponent }
}

public enum DownloadError: Error, LocalizedError, Equatable {
    case notEnoughSpace(needed: Int64, available: Int64)
    case http(Int)
    case checksumMismatch(String)
    case unpackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed, let available):
            "Nicht genug Speicherplatz: \(Self.format(needed)) nötig, \(Self.format(available)) frei."
        case .http(let status): "Der Server antwortet mit Fehler \(status)."
        case .checksumMismatch(let name): "Die Prüfsumme von „\(name)“ stimmt nicht; die Datei wurde verworfen."
        case .unpackFailed(let name): "„\(name)“ ließ sich nicht entpacken."
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Lädt Dateien, prüft SHA-256 und entpackt ZIP-Archive. Lokale `file:`-URLs werden kopiert (Tests, Offline-Quelle).
public enum Downloader {
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Prüft den freien Platz für `bytes` plus Reserve (Faktor 2 für das Entpacken).
    public static func ensureSpace(_ bytes: Int64, at folder: URL) throws {
        guard let available = FileManager.default.availableCapacity(at: folder) else { return }
        let needed = bytes * 2
        if available < needed { throw DownloadError.notEnoughSpace(needed: needed, available: available) }
    }

    /// Lädt `item` nach `folder` und gibt die geprüfte Datei zurück.
    public static func fetch(
        _ item: DownloadItem, into folder: URL, progress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(item.fileName)
        if FileManager.default.fileExists(atPath: target.path), (try? sha256(of: target)) == item.sha256 {
            progress(item.bytes)
            return target
        }
        try? FileManager.default.removeItem(at: target)
        if item.url.isFileURL {
            try FileManager.default.copyItem(at: item.url, to: target)
        } else {
            let delegate = ProgressDelegate(progress)
            let (temporary, response) = try await URLSession.shared.download(from: item.url, delegate: delegate)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: temporary)
                throw DownloadError.http(http.statusCode)
            }
            try FileManager.default.moveItem(at: temporary, to: target)
        }
        progress(item.bytes)
        guard try sha256(of: target) == item.sha256 else {
            try? FileManager.default.removeItem(at: target)
            throw DownloadError.checksumMismatch(item.fileName)
        }
        return target
    }

    /// Entpackt ein ZIP-Archiv mit `ditto` (Teil von macOS).
    public static func unzip(_ archive: URL, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DownloadError.unpackFailed(archive.lastPathComponent) }
    }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let report: @Sendable (Int64) -> Void

    init(_ report: @escaping @Sendable (Int64) -> Void) {
        self.report = report
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        report(totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {}
}
