import Foundation

/// Ein ladbares Modell mit gepinnter Revision und geprüften Dateien.
public struct ModelPackage: Sendable, Identifiable, Equatable {
    public enum Task: String, Sendable {
        case embedding, transcription, vision, language
    }

    public var id: String
    public var task: Task
    public var title: String
    public var license: String
    public var revision: String
    /// ZIP-Archive, die in den Modellordner entpackt werden.
    public var archives: [DownloadItem]
    public var dimension: Int

    public var downloadBytes: Int64 { archives.reduce(0) { $0 + $1.bytes } }

    public var folder: URL {
        Locations.models.appendingPathComponent(task.rawValue, isDirectory: true)
            .appendingPathComponent("\(id)@\(revision.prefix(12))", isDirectory: true)
    }

    private var marker: URL { folder.appendingPathComponent(".installed") }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: marker.path) }

    /// Lädt, prüft und entpackt alle Archive. `source` ersetzt den Server durch einen lokalen Ordner mit denselben Dateien.
    public func install(from source: URL? = nil, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws
    {
        let manager = FileManager.default
        try manager.createDirectory(at: Locations.models, withIntermediateDirectories: true)
        try Downloader.ensureSpace(downloadBytes, at: Locations.models)
        let staging = folder.deletingLastPathComponent().appendingPathComponent(".download-\(id)", isDirectory: true)
        let total = Double(downloadBytes)
        var finished: Int64 = 0
        try? manager.removeItem(at: folder)
        for archive in archives {
            var item = archive
            if let source { item.url = source.appendingPathComponent(archive.fileName) }
            let done = finished
            let file = try await Downloader.fetch(item, into: staging) { bytes in
                progress(Double(done + bytes) / total)
            }
            try Downloader.unzip(file, into: folder)
            finished += archive.bytes
        }
        try Data().write(to: marker)
        try? manager.removeItem(at: staging)
        progress(1)
    }

    public func uninstall() throws {
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
}

/// Modellkatalog. Konkrete IDs und Revisionen stammen aus Spike M0.
public enum ModelCatalog {
    /// SigLIP 2 B/16-256 als Core ML (Apache 2.0): Bild-Text-Embedding, auch mit deutschen Anfragen.
    public static let siglip2: ModelPackage = {
        let base =
            "https://huggingface.co/karaiman/siglip2-base-coreml/resolve/822b48dbd6b1ddffe50c3e80826affddc3357a43/"
        func item(_ name: String, _ sha: String, _ bytes: Int64) -> DownloadItem {
            DownloadItem(url: URL(string: base + name)!, sha256: sha, bytes: bytes)
        }
        return ModelPackage(
            id: "siglip2-b16-256", task: .embedding, title: "SigLIP 2 B/16-256 (Bildsuche)", license: "Apache 2.0",
            revision: "822b48dbd6b1ddffe50c3e80826affddc3357a43",
            archives: [
                item(
                    "ImageEncoder.mlpackage.zip", "0ed362ee28ee2435df2e75669f3c9b0b930812476e4dfdc70e2769350e0e8381",
                    91_700_523),
                item(
                    "TextEncoder.mlpackage.zip", "f38d55639410f7965ce00aceca9496fd113bd4e6d85c9c6a17847415a5185722",
                    258_593_147),
                item("tokenizer.zip", "b8aed2bdd09ce14749ba165199bf580a4e894203f5156a387e9725229c561e89", 5_460_173),
            ],
            dimension: 768)
    }()

    public static let all: [ModelPackage] = [siglip2]
}
