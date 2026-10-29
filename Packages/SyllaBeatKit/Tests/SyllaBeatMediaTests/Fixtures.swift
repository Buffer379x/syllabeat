import Foundation

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
