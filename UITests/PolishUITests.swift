import XCTest

/// Abnahme M7 in der App: Tasten der Bildspur, Willkommen, kleiner Mac (E12), verschobene Medien (E11).
final class PolishUITests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyllaBeatM7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            [
                "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE",
                "-ai.vision.provider", "off",
            ]
            + arguments
        app.launch()
        return app
    }

    @MainActor
    private func canvas(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Timeline:'")).firstMatch
    }

    @MainActor
    private func shotCount(_ app: XCUIApplication) -> Int {
        let label = canvas(app).label
        let match = label.range(of: #"(\d+) Einstellungen"#, options: .regularExpression)
        return match.map { Int(label[$0].split(separator: " ")[0]) ?? -1 } ?? -1
    }

    /// Projekt mit Analyse (41 s, 120 BPM) und sechs analysierten Clips (wie `CutUITests`), ohne Schnitt.
    private func makeProject() throws -> URL {
        var clips: [[String: Any]] = []
        for index in 0..<6 {
            let target = folder.appendingPathComponent("clip-\(index + 1).mov")
            try FileManager.default.copyItem(
                at: fixtures.appendingPathComponent(index.isMultiple(of: 2) ? "strand.mov" : "wald.mov"), to: target)
            clips.append([
                "id": "c\(index + 1)", "media": ["path": target.path],
                "meta": ["duration": 2.4, "fps": "25", "width": 192, "height": 108],
                "scenes": [
                    [
                        "id": "c\(index + 1)-s1", "start": 0.0, "end": 2.4,
                        "features": [
                            "aesthetics": 0.5, "isUtility": false, "faceCount": 0, "shotSize": "medium",
                            "sharpness": 200.0, "motion": Double(index) / 6, "labels": [String](), "brightness": 0.5,
                            "colors": [String](),
                        ],
                    ]
                ],
            ])
        }
        let beats = (0..<81).map { ["time": 0.5 + Double($0) * 0.5, "isDownbeat": $0 % 4 == 0] as [String: Any] }
        let project: [String: Any] = [
            "version": 2, "name": "Tasten", "song": ["path": folder.appendingPathComponent("fehlt.wav").path],
            "analysis": [
                "duration": 41.0, "tempo": 120.0, "meter": 4, "beats": beats,
                "sections": [["id": "a", "kind": "verse", "label": "Strophe", "start": 0.0, "end": 41.0]],
            ],
            "clips": clips,
        ]
        let url = folder.appendingPathComponent("Tasten.syllabeat")
        try JSONSerialization.data(withJSONObject: project).write(to: url)
        return url
    }

    /// B teilt die Einstellung an der Abspielposition (nächster Beat), ⌫ verschmilzt mit der vorigen, ⌘Z nimmt zurück.
    @MainActor
    func testSplitAndMergeWithKeys() throws {
        let app = launch(["-SBOpenDocument", try makeProject().path])
        let timeline = canvas(app)
        let ready = timeline.waitForExistence(timeout: 20) && shotCount(app) > 0
        XCTAssertTrue(
            ready
                || {
                    sleep(5); return shotCount(app) > 0
                }(), "Autopilot hat nicht geschnitten")
        let before = shotCount(app)
        // VoiceOver: Jede Einstellung ist ein eigenes Element mit Clip und Zeit.
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Einstellung 1:'"))
            .firstMatch
        XCTAssertTrue(first.exists, "Einstellungen fehlen für VoiceOver")
        // Klick in die Bildspur bei etwa 1/3: Abspielposition und Auswahl.
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.333, dy: 0.87)).click()
        app.typeKey("b", modifierFlags: [])
        XCTAssertEqual(shotCount(app), before + 1, "B hat nicht geteilt")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(shotCount(app), before, "Undo nach B")
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.87)).click()
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        // Entweder verschmolzen oder abgelehnt, weil der Clip der vorigen Einstellung zu kurz ist (Testclips 2,4 s).
        let refused = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS 'geht nicht' OR label CONTAINS 'geht nicht'")
        )
        .firstMatch
        if refused.waitForExistence(timeout: 2) {
            app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
            XCTAssertEqual(shotCount(app), before, "Abgelehntes Verschmelzen hat trotzdem geändert")
        } else {
            XCTAssertEqual(shotCount(app), before - 1, "⌫ hat nicht verschmolzen")
            app.typeKey("z", modifierFlags: .command)
            XCTAssertEqual(shotCount(app), before, "Undo nach ⌫")
        }
    }

    /// E12: Mit simulierten 16 GB empfiehlt die App die 4-Bit-Variante und warnt vor der 8-Bit-Variante.
    @MainActor
    func testSmallMacRecommendation() throws {
        let app = launch(["-SBOpenDocument", try makeProject().path, "-SBSimulatedMemoryGB", "16"])
        XCTAssertTrue(canvas(app).waitForExistence(timeout: 20))
        app.typeKey(",", modifierFlags: .command)
        let models = app.toolbars.buttons["Modelle"].firstMatch
        XCTAssertTrue(models.waitForExistence(timeout: 5))
        models.click()
        func element(_ id: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: id).firstMatch
        }
        XCTAssertTrue(
            element("model.recommended.qwen3-vl-4b-4bit").waitForExistence(timeout: 5), "4 Bit nicht empfohlen")
        XCTAssertTrue(element("model.tooLarge.qwen3-vl-4b-8bit").exists, "keine Warnung vor 8 Bit")
    }

    /// E11: Clipordner nach dem Sichern verschoben; beim nächsten Öffnen findet die App die Dateien über Bookmarks.
    @MainActor
    func testMovedMediaIsRelinked() throws {
        let material = folder.appendingPathComponent("Material")
        try FileManager.default.createDirectory(at: material, withIntermediateDirectories: true)
        for name in ["strand.mov", "wald.mov"] {
            try FileManager.default.copyItem(
                at: fixtures.appendingPathComponent(name), to: material.appendingPathComponent(name))
        }
        let url = folder.appendingPathComponent("Verschoben.syllabeat")
        try JSONSerialization.data(withJSONObject: ["version": 2, "name": "Verschoben"]).write(to: url)
        var app = launch(["-SBOpenDocument", url.path, "-SBImportPaths", material.path])
        let clip = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'clip.'"))
            .firstMatch
        XCTAssertTrue(clip.waitForExistence(timeout: 30), "Import fehlt")
        sleep(2)
        app.typeKey("s", modifierFlags: .command)
        sleep(1)
        app.terminate()

        let moved = folder.appendingPathComponent("Verschoben nach hier")
        try FileManager.default.moveItem(at: material, to: moved)
        app = launch(["-SBOpenDocument", url.path])
        let banner = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'wiedergefunden' OR value CONTAINS 'wiedergefunden'")
        ).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "keine automatische Neuverknüpfung")
        app.typeKey("s", modifierFlags: .command)
        sleep(1)
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(saved.contains("Verschoben nach hier"), "neue Pfade nicht gesichert")
    }

    /// Erster Start ohne Dokument-Argument: Willkommen erscheint; „ohne KI“ schließt es.
    @MainActor
    func testWelcomeAppearsOnce() throws {
        let app = launch(["-onboarding.done", "NO"])
        // Ohne Dokument zeigt macOS zuerst den Öffnen-Dialog; ein neues Projekt öffnet das Fenster.
        app.typeKey("n", modifierFlags: .command)
        let none = app.buttons["welcome.none"]
        XCTAssertTrue(none.waitForExistence(timeout: 15), "Willkommen fehlt")
        none.click()
        XCTAssertFalse(none.waitForExistence(timeout: 2))
    }
}
