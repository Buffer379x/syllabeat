import XCTest

/// Abnahme 0.4.0 in der App: Timeline-Format, Sperrbereiche, Kapitel, Drehbuch, Tageszeit, Ungereimtheiten.
final class StoryUITests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyllaBeatStory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Projekt mit Songanalyse (41 s, 120 BPM) und `count` analysierten Clips, noch ohne Schnitt.
    private func makeProject(count: Int = 6, extra: [String: Any] = [:]) throws -> URL {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        var clips: [[String: Any]] = []
        for index in 0..<count {
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
        var project: [String: Any] = [
            "version": 3, "name": "Geschichte", "song": ["path": folder.appendingPathComponent("fehlt.wav").path],
            "analysis": analysis, "clips": clips,
        ]
        project.merge(extra) { _, new in new }
        let url = folder.appendingPathComponent("Geschichte.syllabeat")
        try JSONSerialization.data(withJSONObject: project).write(to: url)
        return url
    }

    @MainActor
    private func launch(_ url: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-SBOpenDocument", url.path, "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(de)",
            "-AppleLocale", "de_DE", "-ai.vision.provider", "off",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func savedJSON(_ app: XCUIApplication, _ url: URL) throws -> [String: Any] {
        app.typeKey("s", modifierFlags: .command)
        sleep(1)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @MainActor
    private func waitForCut(_ app: XCUIApplication, _ url: URL) throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if (try? savedJSON(app, url))?["cut"] != nil { return }
            sleep(1)
        }
        XCTFail("Autopilot hat keinen Schnitt erzeugt")
    }

    @MainActor
    func testChangeTimelineRate() throws {
        let url = try makeProject()
        let app = launch(url)
        try waitForCut(app, url)
        let rate = app.popUpButtons["timeline.rate"]
        XCTAssertTrue(rate.waitForExistence(timeout: 10))
        rate.click()
        app.menuItems["30 fps"].click()
        let timeline = try XCTUnwrap(try savedJSON(app, url)["timeline"] as? [String: Any])
        XCTAssertEqual(timeline["fps"] as? String, "30")
        app.typeKey("z", modifierFlags: .command)
        let undone = try XCTUnwrap(try savedJSON(app, url)["timeline"] as? [String: Any])
        XCTAssertEqual(undone["fps"] as? String, "25")
    }

    @MainActor
    private func timeline(_ app: XCUIApplication) -> XCUIElement {
        let canvas = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Timeline:' AND NOT (label CONTAINS ' 0 Einstellungen')")
        ).firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20), "Autopilot hat nicht geschnitten")
        return canvas
    }

    private func clipJSON(_ json: [String: Any], _ id: String) -> [String: Any]? {
        (json["clips"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }

    /// Doppelklick öffnet die Clip-Ansicht; „Sperren“ sperrt ±0,5 s um die Abspielposition; Inspektor und Bibliothek
    /// zeigen die Sperre; ⌘Z nimmt sie zurück.
    @MainActor
    func testBlockRangeInClipViewer() throws {
        let url = try makeProject()
        let app = launch(url)
        _ = timeline(app)
        let tile = app.descendants(matching: .any).matching(identifier: "clip.c1").firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.doubleClick()
        let viewer = app.descendants(matching: .any).matching(identifier: "clipviewer").firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 5), "Clip-Ansicht fehlt")
        app.buttons["clipviewer.block"].click()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "clip.blocked.0").firstMatch.waitForExistence(
                timeout: 5), "Sperrbereich fehlt im Inspektor")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "clip.c1").firstMatch.label.contains("Sperrbereich"),
            "Bibliothek zeigt die Sperre nicht")
        let blocked = try XCTUnwrap(clipJSON(try savedJSON(app, url), "c1")?["blocked"] as? [[String: Any]])
        XCTAssertEqual(blocked.count, 1)
        app.typeKey("z", modifierFlags: .command)
        let undone = clipJSON(try savedJSON(app, url), "c1")?["blocked"] as? [[String: Any]] ?? []
        XCTAssertTrue(undone.isEmpty)
        app.buttons["clipviewer.close"].click()
        XCTAssertFalse(viewer.exists)
    }

    /// X in der Bildspur sperrt den Ausschnitt der ausgewählten Einstellung (ein Undo-Schritt „Ausschnitt sperren“).
    @MainActor
    func testBlockShotFromTimeline() throws {
        let url = try makeProject()
        let app = launch(url)
        let canvas = timeline(app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.87)).click()
        app.typeKey("x", modifierFlags: [])
        let json = try savedJSON(app, url)
        let clips = try XCTUnwrap(json["clips"] as? [[String: Any]])
        XCTAssertTrue(clips.contains { !(($0["blocked"] as? [Any]) ?? []).isEmpty }, "nichts gesperrt")
        app.menuBars.menuBarItems["Bearbeiten"].click()
        let undo = app.menuItems.matching(NSPredicate(format: "title CONTAINS 'Ausschnitt sperren'")).firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "kein Undo-Eintrag „Ausschnitt sperren“")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Zwei Clips wählen, neues Kapitel „Wald“ anlegen, im Drehbuch für Strophe 1 als Hauptkapitel setzen.
    @MainActor
    func testAssignChaptersAndPlan() throws {
        let url = try makeProject()
        let app = launch(url)
        _ = timeline(app)
        let first = app.descendants(matching: .any).matching(identifier: "clip.c1").firstMatch
        let second = app.descendants(matching: .any).matching(identifier: "clip.c2").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.click()
        XCUIElement.perform(withKeyModifiers: .command) { second.click() }
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "inspector.multi").firstMatch.waitForExistence(
                timeout: 5))
        first.rightClick()
        app.menuItems["Kapitel"].hover()
        app.menuItems["Neues Kapitel …"].click()
        let field =
            app.dialogs.textFields.firstMatch.exists ? app.dialogs.textFields.firstMatch : app.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Wald")
        app.buttons["Anlegen"].click()
        let group = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'library.group.k-'")
        ).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5), "keine Gruppe „Wald“ in der Bibliothek")

        app.buttons["toolbar.drehbuch"].click()
        let cell = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'drehbuch.cell.a.'")
        ).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        cell.click()
        cell.click()
        app.buttons["drehbuch.done"].click()
        let json = try savedJSON(app, url)
        let story = try XCTUnwrap(json["story"] as? [String: Any])
        let plan = try XCTUnwrap(story["plan"] as? [String: [String: String]])
        XCTAssertEqual(plan["a"]?.values.first, "main")
        let clips = try XCTUnwrap(json["clips"] as? [[String: Any]])
        XCTAssertEqual(clips.filter { $0["chapterID"] != nil }.count, 2)
    }

    /// Ab 10 Clips ohne Kapitel fragt ein Banner; „Hinweis schließen“ fragt nicht mehr.
    @MainActor
    func testChapterBannerOffersSetup() throws {
        let url = try makeProject(count: 10)
        let app = launch(url)
        _ = timeline(app)
        let banner = app.descendants(matching: .any).matching(identifier: "chapterBanner").firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        banner.buttons["Hinweis schließen"].click()
        XCTAssertFalse(banner.waitForExistence(timeout: 2))
        let story = try XCTUnwrap(try savedJSON(app, url)["story"] as? [String: Any])
        XCTAssertEqual(story["asksForChapters"] as? Bool, false)
    }

    /// Drei Clips wählen, Tageszeit „Abend“ setzen; der Filter „Abend“ zeigt genau diese drei.
    @MainActor
    func testSetTimeOfDayForSeveralClips() throws {
        let url = try makeProject()
        let app = launch(url)
        _ = timeline(app)
        let tiles = (1...3).map { app.descendants(matching: .any).matching(identifier: "clip.c\($0)").firstMatch }
        XCTAssertTrue(tiles[0].waitForExistence(timeout: 10))
        tiles[0].click()
        XCUIElement.perform(withKeyModifiers: .command) {
            tiles[1].click()
            tiles[2].click()
        }
        tiles[0].rightClick()
        app.menuItems["Tageszeit"].hover()
        app.menuItems["Abend"].click()
        let json = try savedJSON(app, url)
        let clips = try XCTUnwrap(json["clips"] as? [[String: Any]])
        let evening = clips.filter {
            (($0["traits"] as? [String: Any])?["tageszeit"] as? [String: Any])?["value"] as? String == "Abend"
        }
        XCTAssertEqual(evening.count, 3)
        app.popUpButtons["library.filter"].click()
        app.menuItems["Abend"].click()
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "clip.c4").firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "clip.c3").firstMatch.exists)
        app.popUpButtons["library.filter"].click()
        app.menuItems["Alle Clips"].click()
    }
}
