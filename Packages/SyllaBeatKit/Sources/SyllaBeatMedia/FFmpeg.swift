import Foundation
import SyllaBeatCore

public enum FFmpegError: Error, LocalizedError, Equatable {
    case missing
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .missing: "Für dieses Format wird die Komponente ffmpeg benötigt (Einstellungen → Allgemein)."
        case .failed(let reason): "Die Arbeitskopie ließ sich nicht erstellen: \(reason)"
        }
    }
}

/// Optionale, nachladbare Komponente für Formate, die AVFoundation nicht liest, und für CFR-Arbeitskopien.
/// Sie wird nicht mitgeliefert, sondern bei Bedarf geladen und per SHA-256 geprüft.
public struct FFmpeg: Sendable {
    public static let workingCopyFolderName = "SyllaBeat-Arbeitskopien"

    /// Gleiche Quelle wie 0.2.0 (`assets/binaries.json`).
    public static let download = DownloadItem(
        url: URL(string: "https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip")!,
        sha256: "c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924", bytes: 28_395_699)

    public enum Preset: String, Sendable, CaseIterable {
        /// Apple ProRes 422 LT: schnell zu schneiden, groß.
        case proResLT
        /// HEVC über die Hardware: klein, etwas langsamer im Schnitt.
        case hevc

        public var title: String {
            switch self {
            case .proResLT: "ProRes 422 LT"
            case .hevc: "HEVC"
            }
        }

        var arguments: [String] {
            switch self {
            case .proResLT:
                ["-c:v", "prores_ks", "-profile:v", "1", "-pix_fmt", "yuv422p10le", "-c:a", "pcm_s16le"]
            case .hevc:
                ["-c:v", "hevc_videotoolbox", "-q:v", "65", "-tag:v", "hvc1", "-c:a", "aac", "-b:a", "256k"]
            }
        }
    }

    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    static var installFolder: URL { Locations.components.appendingPathComponent("ffmpeg", isDirectory: true) }

    /// `SYLLABEAT_FFMPEG` (Entwicklung, Tests) oder die installierte Komponente.
    public static func locate() -> FFmpeg? {
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["SYLLABEAT_FFMPEG"] {
            candidates.append(URL(fileURLWithPath: path))
        }
        candidates.append(installFolder.appendingPathComponent("ffmpeg"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }.map(FFmpeg.init)
    }

    public static var isInstalled: Bool { locate() != nil }

    public static func install(
        from source: URL? = nil, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> FFmpeg {
        var item = download
        if let source { item.url = source.appendingPathComponent(download.fileName) }
        let staging = Locations.components.appendingPathComponent(".download-ffmpeg", isDirectory: true)
        let expected = Double(item.bytes)
        let archive = try await Downloader.fetch(item, into: staging) { progress(min(1, Double($0) / expected)) }
        try? FileManager.default.removeItem(at: installFolder)
        try Downloader.unzip(archive, into: installFolder)
        try? FileManager.default.removeItem(at: staging)
        let binary = installFolder.appendingPathComponent("ffmpeg")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return FFmpeg(executable: binary)
    }

    public static func uninstall() throws {
        if FileManager.default.fileExists(atPath: installFolder.path) {
            try FileManager.default.removeItem(at: installFolder)
        }
    }

    /// Ziel einer Arbeitskopie: Unterordner neben dem Original.
    public static func workingCopyURL(for input: URL) -> URL {
        input.deletingLastPathComponent().appendingPathComponent(workingCopyFolderName, isDirectory: true)
            .appendingPathComponent(input.deletingPathExtension().lastPathComponent).appendingPathExtension("mov")
    }

    /// Wandelt `input` in eine schnittfähige `.mov`-Datei. Mit `constantRate` entsteht eine CFR-Kopie.
    /// Geschrieben wird erst in eine temporäre Datei, dann umbenannt; ein Abbruch hinterlässt nichts.
    public func convert(
        _ input: URL, to output: URL, preset: Preset = .proResLT, constantRate: Rational? = nil,
        progress: @escaping @Sendable (Double?) -> Void = { _ in }
    ) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = output.deletingLastPathComponent().appendingPathComponent(".\(output.lastPathComponent).part.mov")
        try? manager.removeItem(at: partial)
        var arguments = ["-hide_banner", "-nostdin", "-y", "-i", input.path, "-map", "0:v:0", "-map", "0:a:0?"]
        arguments += preset.arguments
        if let constantRate {
            arguments += ["-fps_mode", "cfr", "-r", "\(constantRate.numerator)/\(constantRate.denominator)"]
        }
        arguments += ["-map_metadata", "0", "-progress", "pipe:1", "-nostats", partial.path]
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let state = ConversionState()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            state.appendLog(handle.availableData)
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                guard let micros = Double(line.dropFirst("out_time_us=".count)), let duration = state.duration,
                    duration > 0
                else { continue }
                progress(min(1, micros / 1_000_000 / duration))
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        if Task.isCancelled || process.terminationStatus != 0 {
            try? manager.removeItem(at: partial)
            try Task.checkCancellation()
            throw FFmpegError.failed(state.lastError)
        }
        try? manager.removeItem(at: output)
        try manager.moveItem(at: partial, to: output)
        progress(1)
    }
}

/// Liest Dauer und letzte Fehlermeldung aus der Ausgabe von ffmpeg.
private final class ConversionState: @unchecked Sendable {
    private let lock = NSLock()
    private var log = ""
    private var parsedDuration: Double?

    func appendLog(_ data: Data) {
        lock.withLock {
            log += String(decoding: data, as: UTF8.self)
            if log.count > 20_000 { log = String(log.suffix(10_000)) }
            if parsedDuration == nil, let range = log.range(of: "Duration: ") {
                let text = log[range.upperBound...].prefix(11)
                let parts = text.split(separator: ":").compactMap { Double($0) }
                if parts.count == 3 { parsedDuration = parts[0] * 3600 + parts[1] * 60 + parts[2] }
            }
        }
    }

    var duration: Double? { lock.withLock { parsedDuration } }

    var lastError: String {
        lock.withLock {
            log.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init)
                ?? "unbekannter Fehler"
        }
    }
}
