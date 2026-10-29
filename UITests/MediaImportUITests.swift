import XCTest

/// Abnahme M2 in der App: Ordner importieren, Szenen analysieren, MKV erkennen, beschreiben, suchen, sichern.
final class MediaImportUITests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyllaBeatImport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Material"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    private func labelled(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        ).firstMatch
    }

    @MainActor
    func testImportAnalyseDescribeSearchAndSave() throws {
        let bundle = Bundle(for: Self.self)
        for name in ["strand.mov", "wald.mov", "zwei-farben.mkv"] {
            let source = try XCTUnwrap(bundle.url(forResource: name, withExtension: nil))
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("Material/\(name)"))
        }
        let project = folder.appendingPathComponent("Import.syllabeat")
        try Data(#"{"version": 2, "name": "Import"}"#.utf8).write(to: project)

        let app = XCUIApplication()
        app.launchArguments = [
            "-SBOpenDocument", project.path, "-SBImportPaths", folder.appendingPathComponent("Material").path,
            "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE",
            "-ai.vision.provider", "off",
            "-libraryShowsGrid", "YES", "-libraryFilter", "all",
        ]
        app.launch()

        let beach = labelled(app, "strand.mov")
        XCTAssertTrue(beach.waitForExistence(timeout: 20), "Import fehlt")
        XCTAssertTrue(labelled(app, "wald.mov").exists)
        XCTAssertTrue(labelled(app, "zwei-farben.mkv").exists, "MKV wird nicht angezeigt")

        // Szenen sind analysiert: Der Schnitt bei 1,2 s ergibt zwei Szenen.
        beach.click()
        XCTAssertTrue(labelled(app, "Szenen (2)").waitForExistence(timeout: 20), "Szenenanalyse fehlt")

        // Beschreibung eintragen (Befehl mit Undo) und danach danach suchen.
        let description = app.descendants(matching: .any).matching(identifier: "clip.description").firstMatch
        description.click()
        description.typeText("Blaues Meer am Morgen\r")
        let search = app.descendants(matching: .any).matching(identifier: "library.search").firstMatch
        search.click()
        search.typeText("Meer")
        // Ohne Bildsuche filtert die Suche, mit Bildsuche sortiert sie; der Treffer steht in jedem Fall vorn.
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'clip.c-'"))
            .firstMatch
        let leads = expectation(for: NSPredicate(format: "label CONTAINS 'strand.mov'"), evaluatedWith: first)
        wait(for: [leads], timeout: 5)

        // MKV braucht eine Arbeitskopie.
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        let mkv = labelled(app, "zwei-farben.mkv")
        XCTAssertTrue(mkv.waitForExistence(timeout: 5))
        mkv.click()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "clip.workingCopy").firstMatch.waitForExistence(
                timeout: 5))

        // Sichern: drei Clips, Beschreibung und Szenen stehen in der Datei.
        app.typeKey("s", modifierFlags: .command)
        var saved: [String: Any] = [:]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let data = try? Data(contentsOf: project),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                (object["clips"] as? [Any])?.count == 3
            {
                saved = object
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let clips = try XCTUnwrap(saved["clips"] as? [[String: Any]], "Projekt nicht gesichert")
        let strand = try XCTUnwrap(
            clips.first { ($0["media"] as? [String: Any])?["path"].map { "\($0)" }?.hasSuffix("strand.mov") == true })
        XCTAssertEqual(strand["description"] as? String, "Blaues Meer am Morgen")
        XCTAssertEqual((strand["scenes"] as? [Any])?.count, 2)
        let converted = clips.first { (($0["meta"] as? [String: Any])?["needsConversion"] as? Bool) == true }
        XCTAssertNotNil(converted, "MKV ist nicht als umwandlungsbedürftig markiert")
    }
}
