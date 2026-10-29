import Foundation

/// Zwischenspeicher je Mediendatei: `Caches/<Fingerprint>/`. Fehlt er (anderer Mac, geleert), wird er neu erzeugt.
/// Schlüssel einer Szene ist ihr Start in Millisekunden; dieselbe Erkennung ergibt dieselben Schlüssel.
public struct MediaCache: Sendable {
    public let root: URL

    public init(root: URL = Locations.caches) {
        self.root = root
    }

    public func folder(for fingerprint: String) -> URL {
        let safe = fingerprint.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "_")
        return root.appendingPathComponent(safe, isDirectory: true)
    }

    public static func key(forSceneStart start: Double) -> String {
        String(Int((start * 1000).rounded()))
    }

    public func thumbnail(fingerprint: String, sceneStart: Double) -> URL {
        folder(for: fingerprint).appendingPathComponent("thumb-\(Self.key(forSceneStart: sceneStart)).heic")
    }

    /// Kleine Bilder über die ganze Cliplänge, nebeneinander in einer Datei (für Skimming).
    public func filmstrip(fingerprint: String) -> URL {
        folder(for: fingerprint).appendingPathComponent("filmstrip.heic")
    }

    /// Wellenform eines Songs (Minimum/Maximum je 10 ms).
    public func waveform(fingerprint: String) -> URL {
        folder(for: fingerprint).appendingPathComponent("waveform.f16")
    }

    public func embeddings(fingerprint: String, model: String) -> URL {
        folder(for: fingerprint).appendingPathComponent("embeddings-\(model).plist")
    }

    public func prepare(fingerprint: String) throws -> URL {
        let url = folder(for: fingerprint)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Zugriffszeit für die Bereinigung (älteste zuerst).
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    public func size() -> Int64 {
        FileManager.default.allocatedSize(of: root)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        for item in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: item)
        }
    }

    /// Löscht die am längsten unbenutzten Ordner, bis höchstens `maximumBytes` belegt sind.
    @discardableResult
    public func trim(toBytes maximumBytes: Int64) throws -> Int {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return 0 }
        let folders = try manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        )
        .map {
            (
                $0,
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            )
        }
        .sorted { $0.1 < $1.1 }
        var total = size()
        var removed = 0
        for (folder, _) in folders where total > maximumBytes {
            total -= manager.allocatedSize(of: folder)
            try manager.removeItem(at: folder)
            removed += 1
        }
        return removed
    }
}

/// Embeddings eines Clips für ein Modell, Schlüssel: Szenenstart in ms.
public struct EmbeddingFile: Codable, Sendable, Equatable {
    public var model: String
    public var dimension: Int
    public var vectors: [String: [Float]]

    public init(model: String, dimension: Int, vectors: [String: [Float]] = [:]) {
        self.model = model
        self.dimension = dimension
        self.vectors = vectors
    }

    public static func read(_ url: URL) -> EmbeddingFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(EmbeddingFile.self, from: data)
    }

    public func write(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
