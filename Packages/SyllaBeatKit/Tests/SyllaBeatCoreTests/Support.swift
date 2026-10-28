import Foundation

enum Fixtures {
    /// Wurzel des Repositorys, ermittelt aus dem Pfad dieser Datei.
    static let repository: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    static let golden = repository.appendingPathComponent("tests/Fixtures/golden-v0.2.0")
    static let goldenNames = ["g1-basis-25p", "g2-ntsc-umlaute", "g3-hochformat-5994", "g4-manueller-plan"]

    /// Mit dem Python-Code von 0.2.0 erzeugtes Projekt aus synthetischem Material; liegt nur lokal vor.
    static let localLegacyProject = repository.appendingPathComponent("work/testmaterial/legacy/Altprojekt.syllabeat")

    static func data(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    static func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data(url)) as! [String: Any]
    }
}
