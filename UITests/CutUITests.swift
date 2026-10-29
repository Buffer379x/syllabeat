import XCTest

/// Abnahme M4 in der App: Autopilot schneidet, Shot auswählen, fixieren (L), neu würfeln (⌘R), rückgängig.
final class CutUITests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyllaBeatCut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Projekt mit fertiger Songanalyse (41 s, 120 BPM, Refrain mit Wiederholung) und sechs analysierten Clips, aber
    /// noch ohne Schnitt: Der Autopilot muss ihn beim Öffnen erzeugen.
    private func makeProject() throws -> URL {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        var clips: [[String: Any]] = []
        for index in 0..<6 {
            let source = fixtures.appendingPathComponent(index.isMultiple(of: 2) ? "strand.mov" : "wald.mov")
            let target = folder.appendingPathComponent("clip-\(index + 1).mov")
            try FileManager.default.copyItem(at: source, to: target)
            clips.append([
                "id": "c\(index + 1)", "media": ["path": target.path],
                "meta": ["duration": 2.4, "fps": "25", "width": 192, "height": 108],
                "scenes": [
                    [
                        "id": "c\(index + 1)-s1", "start": 0.0, "end": 2.4,
                        "features": [
                            "aesthetics": Double(index) / 6, "isUtility": false, "faceCount": 0, "shotSize": "medium",
                            "sharpness": 200.0, "motion": Double(index) / 6, "labels": [String](), "brightness": 0.5,
                            "colors": [String](),
                        ],
                    ]
                ],
            ])
        }
        let beats = (0..<81).map { ["time": 0.5 + Double($0) * 0.5, "isDownbeat": $0 % 4 == 0] as [String: Any] }
        let analysis: [String: Any] = [
            "duration": 41.0, "tempo": 120.0, "meter": 4, "beats": beats,
            "sections": [
                ["id": "a", "kind": "verse", "label": "Strophe 1", "start": 0.0, "end": 16.5],
                ["id": "b", "kind": "chorus", "label": "Refrain", "start": 16.5, "end": 24.5],
                ["id": "c", "kind": "verse", "label": "Strophe 2", "start": 24.5, "end": 32.5],
                ["id": "d", "kind": "chorus", "label": "Refrain", "start": 32.5, "end": 40.5, "repeatOf": "b"],
                ["id": "e", "kind": "outro", "label": "Outro", "start": 40.5, "end": 41.0],
            ],
        ]
        let project: [String: Any] = [
            "version": 2, "name": "Schnitt", "song": ["path": folder.appendingPathComponent("fehlt.wav").path],
            "analysis": analysis, "clips": clips,
        ]
        let url = folder.appendingPathComponent("Schnitt.syllabeat")
        try JSONSerialization.data(withJSONObject: project).write(to: url)
        return url
    }

    @MainActor
    private func saved(_ app: XCUIApplication, _ url: URL) throws -> [String: Any] {
        app.typeKey("s", modifierFlags: .command)
        sleep(1)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return try XCTUnwrap(json?["cut"] as? [String: Any], "kein Schnitt gespeichert")
    }

    @MainActor
    func testAutopilotLockRerollUndo() throws {
        let url = try makeProject()
        let app = XCUIApplication()
        app.launchArguments = [
            "-SBOpenDocument", url.path, "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(de)",
            "-AppleLocale", "de_DE", "-ai.vision.provider", "off",
        ]
        app.launch()

        // Autopilot: Die Bildspur füllt sich und die Vorschau zeigt Bild.
        let canvas = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Timeline:' AND NOT (label CONTAINS ' 0 Einstellungen')")
        ).firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20), "Autopilot hat nicht geschnitten")
        let video = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Vorschau des Schnitts'"))
            .firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 10), "Vorschau ohne Bild")
        let first = try saved(app, url)
        let firstShots = try XCTUnwrap(first["shots"] as? [[String: Any]])
        XCTAssertGreaterThan(firstShots.count, 8)
        // Refrain identisch: Die Wiederholung verweist auf ihre Vorlage.
        XCTAssertTrue(
            firstShots.contains { (($0["reasons"] as? [String: Any])?["copiedFrom"] as? String) != nil },
            "keine Kopie im wiederholten Refrain")

        // Shot in der Bildspur auswählen (Spur unten in der Zeichenfläche): Der Inspektor zeigt die Begründung.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.87)).click()
        let reasons = app.descendants(matching: .any).matching(identifier: "shot.reasons").firstMatch
        XCTAssertTrue(reasons.waitForExistence(timeout: 5), "„Warum dieser Clip?“ fehlt")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "shot.alternatives").firstMatch.exists)

        // L fixiert, ⌘R würfelt neu: Der fixierte Shot bleibt, der Seed ändert sich.
        app.typeKey("l", modifierFlags: [])
        let locked = try saved(app, url)
        let lockedShots = try XCTUnwrap(locked["shots"] as? [[String: Any]])
        let lockedShot = try XCTUnwrap(lockedShots.first { $0["locked"] as? Bool == true }, "nichts fixiert")
        app.typeKey("r", modifierFlags: .command)
        let rerolled = try saved(app, url)
        XCTAssertNotEqual(rerolled["seed"] as? Int, locked["seed"] as? Int)
        let rerolledShots = try XCTUnwrap(rerolled["shots"] as? [[String: Any]])
        let kept = rerolledShots.first {
            ($0["start"] as? [String: Any])?["time"] as? Double
                == (lockedShot["start"] as? [String: Any])?["time"] as? Double
        }
        XCTAssertEqual(kept?["clipID"] as? String, lockedShot["clipID"] as? String)
        XCTAssertEqual(kept?["sourceIn"] as? String, lockedShot["sourceIn"] as? String)
        XCTAssertEqual(kept?["locked"] as? Bool, true)

        // Rückgängig stellt den Schnitt vor dem Würfeln wieder her.
        app.typeKey("z", modifierFlags: .command)
        let undone = try saved(app, url)
        XCTAssertEqual(undone["seed"] as? Int, locked["seed"] as? Int)
        XCTAssertEqual((undone["shots"] as? [[String: Any]])?.count, lockedShots.count)
    }

    /// Export für DaVinci Resolve: Dialog, Zielprogramm, Dateien mit Markern, Bildrate und Dauer aus dem Schnitt.
    @MainActor
    func testExportForResolve() throws {
        let url = try makeProject()
        // Der Export prüft, ob die Medien da sind: kurzer Song an der erwarteten Stelle.
        try Data(count: 1024).write(to: folder.appendingPathComponent("fehlt.wav"))
        let exports = folder.appendingPathComponent("Exporte")
        let app = XCUIApplication()
        app.launchArguments = [
            "-SBOpenDocument", url.path, "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(de)",
            "-AppleLocale", "de_DE", "-ai.vision.provider", "off", "-export.folder", exports.path,
            "-export.target", "resolve",
        ]
        app.launch()
        let canvas = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Timeline:' AND NOT (label CONTAINS ' 0 Einstellungen')")
        ).firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20), "Autopilot hat nicht geschnitten")
        app.typeKey("e", modifierFlags: .command)
        let run = app.buttons["export.run"]
        XCTAssertTrue(run.waitForExistence(timeout: 5), "Export-Dialog fehlt")
        run.click()
        let done = app.descendants(matching: .any).matching(identifier: "export.done").firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Export nicht fertig")
        let files = try FileManager.default.contentsOfDirectory(atPath: exports.path).sorted()
        XCTAssertEqual(
            files, ["Schnitt Marker.edl", "Schnitt.edl", "Schnitt.fcpxml", "clip-katalog.json", "schnittliste.json"])
        // Resolve bekommt FCPXML (mit Song), dazu EDL und Marker-EDL.
        let xml = try String(contentsOf: exports.appendingPathComponent("Schnitt.fcpxml"), encoding: .utf8)
        XCTAssertTrue(xml.contains("duration=\"41s\" tcStart"), "Sequenzdauer 41 s")
        XCTAssertTrue(xml.contains("value=\"Refrain\""), "Abschnittsmarker fehlt")
        XCTAssertTrue(xml.contains("audioRole=\"dialogue.music\""), "Song fehlt")
        let edl = try String(contentsOf: exports.appendingPathComponent("Schnitt.edl"), encoding: .utf8)
        XCTAssertTrue(edl.hasPrefix("TITLE: Schnitt\nFCM: NON-DROP FRAME"))
    }
}
