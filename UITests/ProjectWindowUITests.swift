import XCTest

/// Abnahme M1: Ein 0.2.0-Projekt öffnet, zeigt Clips und Beats, Undo/Redo greift, Sichern schreibt v2.
final class ProjectWindowUITests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyllaBeatUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    private func launch(opening url: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-SBOpenDocument", url.path, "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(de)",
            "-AppleLocale", "de_DE", "-ai.vision.provider", "off",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func labelled(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    func testLegacyProjectOpensUndoesAndSavesAsVersion2() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "legacy-g1", withExtension: "json"))
        let url = folder.appendingPathComponent("Basis.syllabeat")
        try FileManager.default.copyItem(at: fixture, to: url)
        let app = launch(opening: url)

        // Clipnamen und Beatanzahl aus 0.2.0 sind sichtbar.
        let beach = element(app, "clip.clip-a")
        XCTAssertTrue(beach.waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "clip.clip-b").exists)
        XCTAssertTrue(element(app, "clip.clip-c").exists)
        XCTAssertTrue(labelled(app, "24 Beats").exists, "Beatanzahl fehlt")
        XCTAssertTrue(labelled(app, "Einstellungen").exists, "Schnitt fehlt")
        XCTAssertTrue(element(app, "migrationBanner").exists)
        let backup = folder.appendingPathComponent("Basis (0.2).syllabeat")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "Sicherungskopie fehlt")

        // Testbefehl mit Undo/Redo.
        beach.click()
        let excluded = element(app, "clip.excluded")
        XCTAssertTrue(excluded.waitForExistence(timeout: 5))
        XCTAssertEqual(excluded.value as? Int, 0)
        XCTAssertTrue(excluded.isHittable, "„Nie verwenden“ liegt außerhalb des sichtbaren Bereichs")
        excluded.click()
        XCTAssertEqual(excluded.value as? Int, 1)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(excluded.value as? Int, 0)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(excluded.value as? Int, 1)

        // Sichern schreibt Format v2; die Kopie bleibt im alten Format.
        app.typeKey("s", modifierFlags: .command)
        let saved = expectation(description: "v2 gesichert")
        let deadline = Date().addingTimeInterval(10)
        var project: [String: Any] = [:]
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["version"] as? Int == 2
            {
                project = object
                saved.fulfill()
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        wait(for: [saved], timeout: 1)
        let clips = try XCTUnwrap(project["clips"] as? [[String: Any]])
        XCTAssertEqual(clips.first?["excluded"] as? Bool, true)
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any]
        XCTAssertEqual(original?["version"] as? Int, 1)
    }

    /// Der XPC-Dienst startet auf Anfrage und antwortet; die Prüfung läuft über die Aufgabenzentrale.
    @MainActor
    func testInferenceServiceAnswers() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "legacy-g1", withExtension: "json"))
        let url = folder.appendingPathComponent("Dienst.syllabeat")
        try FileManager.default.copyItem(at: fixture, to: url)
        let app = launch(opening: url)
        XCTAssertTrue(element(app, "clip.clip-a").waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        // Das Einstellungsfenster merkt sich den letzten Bereich.
        let general = app.toolbars.buttons["Allgemein"].firstMatch
        if general.waitForExistence(timeout: 5) { general.click() }
        let check = element(app, "settings.checkInference")
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        check.click()
        let ready = element(app, "settings.inferenceReady")
        XCTAssertTrue(ready.waitForExistence(timeout: 15), "Dienst antwortet nicht")
        let firstLabel = ready.label

        // E8: Der Dienst stürzt ab (hier: hart beendet). Die App bleibt bedienbar und verbindet sich neu.
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-9", "-x", "SyllaBeatInference"]
        try kill.run()
        kill.waitUntilExit()
        sleep(1)
        check.click()
        XCTAssertTrue(ready.waitForExistence(timeout: 20), "Dienst nach dem Absturz nicht wieder erreichbar")
        if kill.terminationStatus == 0 {
            XCTAssertNotEqual(ready.label, firstLabel, "gleiche PID – Dienst wurde nicht neu gestartet")
        }
    }
}
