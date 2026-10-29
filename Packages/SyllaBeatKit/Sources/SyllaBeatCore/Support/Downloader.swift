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
        _ item: DownloadItem, into folder: URL, configuration: URLSessionConfiguration = .default,
        progress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(item.fileName)
        if FileManager.default.fileExists(atPath: target.path), (try? sha256(of: target)) == item.sha256 {
            progress(item.bytes)
            return target
        }
        if item.url.isFileURL {
            // Lokale Quelle (z. B. Hugging-Face-Zwischenspeicher): Verweise auflösen, die Datei selbst kopieren.
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: item.url.resolvingSymlinksInPath(), to: target)
        } else {
            // Fortsetzbar: Der Teil-Download liegt in `.part` und wird mit einer Range-Anfrage weitergeladen.
            let partial = target.appendingPathExtension("part")
            try await RangeDownload(url: item.url, file: partial, configuration: configuration, report: progress).run()
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: partial, to: target)
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

/// Lädt eine Datei in Teilen auf die Platte und setzt einen abgebrochenen Download fort (HTTP Range).
final class RangeDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let file: URL
    private let report: @Sendable (Int64) -> Void
    private let configuration: URLSessionConfiguration
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var continuation: CheckedContinuation<Void, any Error>?
    private var failure: (any Error)?

    init(url: URL, file: URL, configuration: URLSessionConfiguration, report: @escaping @Sendable (Int64) -> Void) {
        self.url = url
        self.file = file
        self.configuration = configuration
        self.report = report
    }

    func run() async throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: file.path) { manager.createFile(atPath: file.path, contents: nil) }
        written = (try? manager.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        var request = URLRequest(url: url)
        if written > 0 { request.setValue("bytes=\(written)-", forHTTPHeaderField: "Range") }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.continuation = continuation
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else {
            failure = DownloadError.http(status)
            completionHandler(.cancel)
            return
        }
        do {
            let handle = try FileHandle(forWritingTo: file)
            if status == 200 {
                // Server ohne Range-Unterstützung: von vorn.
                try handle.truncate(atOffset: 0)
                written = 0
            } else {
                try handle.seekToEnd()
            }
            self.handle = handle
            report(written)
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            written += Int64(data.count)
            report(written)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        try? handle?.close()
        handle = nil
        if let failure = failure ?? error {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
