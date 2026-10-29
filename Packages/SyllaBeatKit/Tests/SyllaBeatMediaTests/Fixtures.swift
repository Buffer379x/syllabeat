import Foundation
import Testing

enum TestFolder {
    static func make(_ name: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SyllaBeatMediaTests-\(name.filter(\.isLetter))-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let repository: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    static let media = repository.appendingPathComponent("tests/Fixtures/media")
    static let mkv = media.appendingPathComponent("zwei-farben.mkv")

    /// Fester Testclip aus `tools/make_media_fixtures.py`.
    static func clip(_ name: String) -> URL { media.appendingPathComponent(name) }
}

/// GitHub-Runner sind virtuelle Macs ohne Medien-Scaler: Verkleinertes Dekodieren (AVAssetReader mit Zielgröße,
/// AVAssetImageGenerator) hängt dort. Diese Tests laufen nur auf echter Hardware (lokal über `scripts/check.sh`).
enum Hardware {
    static let isVirtualMachine: Bool = {
        // Zur Fehlersuche lassen sich die Tests auch auf VMs erzwingen.
        if ProcessInfo.processInfo.environment["SYLLABEAT_VM_MEDIA_TESTS"] != nil { return false }
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
    }()

    static let reason: Comment = "Virtueller Mac ohne Medien-Scaler; läuft lokal auf echter Hardware"
}
