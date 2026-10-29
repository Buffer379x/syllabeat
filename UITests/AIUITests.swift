import XCTest

/// Abnahme M5 in der App (ohne Modell, läuft im CI): Storyboard über den manuellen Anbieter, Prüfung der eingefügten
/// Antwort, Übernahme mit Neuschnitt, Undo.
final class AIUITests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyllaBeatAI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Projekt mit Songanalyse (zwei Abschnitte, eine Textzeile), aber ohne Clips: Das Storyboard braucht nur den Song.
    private func makeProject() throws -> URL {
        let beats = (0..<60).map { ["time": 0.5 + Double($0) * 0.5, "isDownbeat": $0 % 4 == 0] as [String: Any] }
        let analysis: [String: Any] = [
            "duration": 30.0, "tempo": 120.0, "meter": 4, "beats": beats,
            "sections": [
                ["id": "a", "kind": "verse", "label": "Strophe", "start": 0.0, "end": 16.5],
                ["id": "b", "kind": "chorus", "label": "Refrain", "start": 16.5, "end": 30.0],
            ],
            "lines": [["id": "l1", "text": "Und das Meer singt mit", "start": 17.0, "end": 19.0]],
        ]
        let project: [String: Any] = [
            "version": 2, "name": "Regie", "song": ["path": folder.appendingPathComponent("fehlt.wav").path],
            "brief": "Liebesgeschichte am Meer", "analysis": analysis,
        ]
        let url = folder.appendingPathComponent("Regie.syllabeat")
        try JSONSerialization.data(withJSONObject: project).write(to: url)
        return url
    }

    @MainActor
    func testManualStoryboardIsValidatedAppliedAndUndone() throws {
        let url = try makeProject()
        let app = XCUIApplication()
        app.launchArguments = [
            "-SBOpenDocument", url.path, "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(de)",
            "-AppleLocale", "de_DE", "-ai.director.provider", "manual", "-ai.vision.provider", "off",
        ]
        app.launch()
        let create = app.buttons["director.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 15), "Regie-Bereich fehlt")
        create.click()

        // Ungültige Antwort: Die Prüfung meldet die Abweichung, nichts wird übernommen.
        let answer = app.textViews["manual.answer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 5), "Prompt-Fenster fehlt")
        answer.click()
        answer.typeText("{\"idee\": \"Meer\"}")
        app.buttons["Übernehmen"].click()
        let problem = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'abschnitte fehlt' OR value CONTAINS 'abschnitte fehlt'")
        ).firstMatch
        XCTAssertTrue(problem.waitForExistence(timeout: 5), "Prüfung meldet nichts")

        // Gültige Antwort: übernommen, Idee steht im Inspektor.
        answer.click()
        answer.typeKey("a", modifierFlags: .command)
        answer.typeText(
            """
            {"idee": "Zwei am Meer bei Nacht", "abschnitte": [{"abschnitt": "a", "stimmung": "ruhig", "bildidee": "Strand", \
            "suchbegriffe": ["Strand", "Wellen", "Sand"], "schnitttempo": "ruhig"}]}
            """)
        app.buttons["Übernehmen"].click()
        let idea = app.staticTexts["director.idea"]
        XCTAssertTrue(idea.waitForExistence(timeout: 5), "Storyboard nicht übernommen")
        XCTAssertEqual(idea.value as? String ?? idea.label, "Zwei am Meer bei Nacht")

        // Rückgängig entfernt das Storyboard wieder.
        app.typeKey("z", modifierFlags: .command)
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: idea)
        wait(for: [gone], timeout: 5)

        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(idea.waitForExistence(timeout: 5))
        app.typeKey("s", modifierFlags: .command)
        sleep(1)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let storyboard = saved?["storyboard"] as? [String: Any]
        XCTAssertEqual(storyboard?["idea"] as? String, "Zwei am Meer bei Nacht")
        XCTAssertEqual((storyboard?["sections"] as? [[String: Any]])?.count, 2, "fehlender Abschnitt nicht ergänzt")
    }
}
