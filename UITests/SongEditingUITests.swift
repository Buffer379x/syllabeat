import XCTest

/// Abnahme M3 in der App: Raster-Werkzeuge mit Undo/Redo und Abschnitt per Kontextmenü.
final class SongEditingUITests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyllaBeatSong-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Projekt mit fertiger Songanalyse: 120 BPM, drei Abschnitte, eine unsichere Textzeile.
    private func makeProject() throws -> URL {
        let beats = (0..<80).map { ["time": 0.5 + Double($0) * 0.5, "isDownbeat": $0 % 4 == 0] as [String: Any] }
        let analysis: [String: Any] = [
            "duration": 41.0, "tempo": 120.0, "meter": 4, "beats": beats,
            "sections": [
                ["id": "a", "kind": "verse", "label": "Strophe", "start": 0.0, "end": 16.5],
                ["id": "b", "kind": "verse", "label": "Strophe", "start": 16.5, "end": 32.5],
                ["id": "c", "kind": "outro", "label": "Outro", "start": 32.5, "end": 41.0],
            ],
            "words": [["id": "w1", "text": "Meer", "start": 2.0, "end": 2.4, "confidence": 0.2]],
            "lines": [["id": "l1", "text": "Meer", "start": 2.0, "end": 2.4, "needsReview": true, "wordIDs": ["w1"]]],
        ]
        let project: [String: Any] = [
            "version": 2, "name": "Raster", "song": ["path": folder.appendingPathComponent("fehlt.wav").path],
            "analysis": analysis,
        ]
        let url = folder.appendingPathComponent("Raster.syllabeat")
        try JSONSerialization.data(withJSONObject: project).write(to: url)
        return url
    }

    @MainActor
    private func labelled(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        )
        .firstMatch
    }

    @MainActor
    func testGridToolsUndoAndSectionMenu() throws {
        let url = try makeProject()
        let app = XCUIApplication()
        app.launchArguments = ["-SBOpenDocument", url.path, "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(labelled(app, "120,0 BPM").waitForExistence(timeout: 15), "Timeline fehlt")

        // Tempo ×2, rückgängig, wiederholen.
        app.menuButtons["Tempo"].click()
        app.menuItems["Tempo ×2"].click()
        XCTAssertTrue(labelled(app, "240,0 BPM").waitForExistence(timeout: 5))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(labelled(app, "120,0 BPM").waitForExistence(timeout: 5))
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(labelled(app, "240,0 BPM").waitForExistence(timeout: 5))

        // Abschnittstyp über das Kontextmenü der Abschnittsspur.
        let canvas = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Timeline:'"))
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.07)).rightClick()
        app.menuItems["Typ"].hover()
        app.menuItems["Refrain"].click()

        // Versatz +10 ms und zurück.
        app.buttons["+10 ms"].click()
        app.typeKey("z", modifierFlags: .command)

        app.typeKey("s", modifierFlags: .command)
        var saved: [String: Any] = [:]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let analysis = object["analysis"] as? [String: Any], (analysis["tempo"] as? Double) == 240
            {
                saved = analysis
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let beats = try XCTUnwrap(saved["beats"] as? [[String: Any]], "nicht gesichert")
        XCTAssertEqual(beats.count, 159)
        XCTAssertEqual(beats.first?["time"] as? Double, 0.5, "Versatz wurde nicht rückgängig gemacht")
        let sections = try XCTUnwrap(saved["sections"] as? [[String: Any]])
        XCTAssertEqual(sections.first?["kind"] as? String, "chorus")
    }
}
