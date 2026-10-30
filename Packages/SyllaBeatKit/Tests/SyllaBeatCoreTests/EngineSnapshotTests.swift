import Foundation
import Testing

@testable import SyllaBeatCore

/// Schnitte ohne Geschichte, ohne Sperrbereiche und ohne Text-Ähnlichkeiten bleiben bitgleich zu 0.3.0. Die Prüfsummen
/// stammen aus der Engine von 0.3.0; neu aufnehmen mit `SYLLABEAT_RECORD=1` (nur bei bewusster Änderung).
@Suite struct EngineSnapshotTests {
    static let fixture = Fixtures.repository.appendingPathComponent(
        "Packages/SyllaBeatKit/Tests/SyllaBeatCoreTests/Fixtures/engine-0.3.0.json")

    static func checksum(_ cut: Cut?) -> String {
        guard let cut else { return "kein Schnitt" }
        let text = cut.shots.map { shot in
            "\(shot.clipID)|\(shot.sceneID ?? "")|\(shot.sourceIn.numerator)/\(shot.sourceIn.denominator)|"
                + "\(shot.start.time)|\(shot.end.time)|\(shot.start.anchor)"
        }
        .joined(separator: ";")
        return String(SeededRandom.hash(text), radix: 16)
    }

    @Test func cutsMatch030() throws {
        var current: [String] = []
        for seed in UInt64(0)..<200 {
            let project = SyntheticProject.make(seed: seed)
            current.append(Self.checksum(CutEngine.generate(project, style: project.style, textScores: TextScores())))
        }
        if ProcessInfo.processInfo.environment["SYLLABEAT_RECORD"] == "1" {
            try FileManager.default.createDirectory(
                at: Self.fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(current).write(to: Self.fixture)
            Issue.record("Snapshot neu aufgenommen – ohne SYLLABEAT_RECORD erneut ausführen.")
            return
        }
        let expected = try JSONDecoder().decode([String].self, from: Data(contentsOf: Self.fixture))
        let differing = zip(expected, current).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(differing.isEmpty, "Seeds mit anderem Schnitt als 0.3.0: \(differing.prefix(10))")
        #expect(expected.count == current.count)
    }
}
