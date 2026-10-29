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
    /// Dateien: ZIP-Archive werden in den Modellordner entpackt, alle anderen unverändert hineingelegt.
    public var archives: [DownloadItem]
    public var dimension: Int
    /// Arbeitsspeicher beim Rechnen (Spitze), für die Empfehlung.
    public var memoryBytes: Int64 = 0

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
            if archive.fileName.hasSuffix(".zip") {
                try Downloader.unzip(file, into: folder)
            } else {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent(archive.fileName)
                try? manager.removeItem(at: target)
                if source != nil {
                    try manager.copyItem(at: file, to: target)
                } else {
                    try manager.moveItem(at: file, to: target)
                }
            }
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

    /// Qwen3-VL-4B-Instruct (Apache 2.0) für MLX: Bildbeschreibungen und Storyboard ohne Apple Intelligence.
    /// M0: 7,6 s je Clip mit 4 Szenen, Schema 4/4 eingehalten.
    public static let qwen3VL8bit = qwen3VL(
        id: "qwen3-vl-4b-8bit", repository: "mlx-community/Qwen3-VL-4B-Instruct-8bit",
        title: "Qwen3-VL 4B, 8 Bit (Bildbeschreibung, Regie)",
        revision: "0943db6e15185b86be368d3cf0704aec740b142b", memory: 6_300_000_000,
        files: [
            ("config.json", "abe3e847cdd84379a4754e5821ceda19226fda74fcf0b4436a966d3c2fbb68e7", 7137),
            ("model.safetensors", "49313ba7eb04191cb38fff8486ff87436d5fb6dcbb3eb9a32df250b0bef7f60d", 5_104_903_807),
        ])

    /// Kleinere Variante für Macs mit 16 GB oder weniger.
    public static let qwen3VL4bit = qwen3VL(
        id: "qwen3-vl-4b-4bit", repository: "mlx-community/Qwen3-VL-4B-Instruct-4bit",
        title: "Qwen3-VL 4B, 4 Bit (für 16 GB)", revision: "2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b",
        memory: 4_200_000_000,
        files: [
            ("config.json", "07406d087dfb8a8849427a4da81bc9edd1dd942e518493629b5a983169b47820", 7137),
            ("model.safetensors", "90eeb02604181dbcccd0a30a1f550a4a8928ca7dcbee4aee1449239306cfdfca", 3_093_767_283),
        ])

    /// Gemeinsame Dateien beider Varianten (Tokenizer, Vorlagen, Vorverarbeitung).
    private static let qwen3VLShared: [(String, String, Int64)] = [
        ("added_tokens.json", "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680", 707),
        ("chat_template.jinja", "3636d0f0bd6bef02654cdffdc447b79cb2cef8ab02cc75267345946291a489e4", 5292),
        ("chat_template.json", "6f8a6a55027e3da5160105556cda5dd69f6423f1c32645f6730d32de7773d0c4", 5502),
        ("generation_config.json", "8469742d1fce0de951c8909b26a2c0c0d8490837ce476efb114da9e0cefc4d44", 269),
        ("model.safetensors.index.json", "58a7841d7bff2548dd91577d216274a83cf1b500bc6a534b809d6c1b1707cf2b", 64742),
        ("preprocessor_config.json", "93585062a80db5e8ca038efc7726a3e6411d9db948472d81d63c6303993be8c5", 782),
        ("special_tokens_map.json", "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd", 613),
        ("tokenizer.json", "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4", 11_422_654),
        ("tokenizer_config.json", "81ec7bb9530159b326c0bef1d0b6c33d392090524014ea3f0123a3c1eb9c2af5", 5445),
        ("video_preprocessor_config.json", "59c5c9eb52182eb14c06ffb10ca9effd29adce5f238a95de23ca14a38dbd2cb1", 817),
        ("vocab.json", "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910", 2_776_833),
    ]

    private static func qwen3VL(
        id: String, repository: String, title: String, revision: String, memory: Int64,
        files: [(String, String, Int64)]
    ) -> ModelPackage {
        let base = "https://huggingface.co/\(repository)/resolve/\(revision)/"
        var package = ModelPackage(
            id: id, task: .vision, title: title, license: "Apache 2.0", revision: revision,
            archives: (qwen3VLShared + files).map { name, sha, bytes in
                DownloadItem(url: URL(string: base + name)!, sha256: sha, bytes: bytes)
            }, dimension: 0)
        package.memoryBytes = memory
        return package
    }

    /// Empfohlenes lokales Bildmodell für diesen Mac (Plan 7.2): bis 16 GB die 4-Bit-Variante.
    public static func recommendedVision(memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> ModelPackage {
        memory <= 16 * 1_073_741_824 ? qwen3VL4bit : qwen3VL8bit
    }

    public static let all: [ModelPackage] = [siglip2, qwen3VL8bit, qwen3VL4bit]

    public static func package(id: String) -> ModelPackage? { all.first { $0.id == id } }
}
