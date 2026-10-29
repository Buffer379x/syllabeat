import XCTest

/// Bildschirmfotos für die Abnahme. Läuft nur, wenn `SB_REVIEW_PROJECT` gesetzt ist
/// (bei xcodebuild: `TEST_RUNNER_SB_REVIEW_PROJECT=<Pfad>`); die Bilder landen als Anhänge im Ergebnisbündel.
final class ReviewScreenshots: XCTestCase {
    @MainActor
    func testCaptureProjectWindow() throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try XCTUnwrap(environment["SB_REVIEW_PROJECT"], "SB_REVIEW_PROJECT nicht gesetzt")
        let app = XCUIApplication()
        app.launchArguments = [
            "-SBOpenDocument", path, "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(de)", "-AppleLocale",
            "de_DE",
        ]
        if let folder = environment["SB_REVIEW_IMPORT"] { app.launchArguments += ["-SBImportPaths", folder] }
        if let appearance = environment["SB_REVIEW_APPEARANCE"] {
            app.launchArguments += ["-AppleInterfaceStyle", appearance]
        }
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        sleep(1)
        attach(window.screenshot(), "Fenster")
        if environment["SB_REVIEW_IMPORT"] != nil {
            // Warten, bis Import und Analyse fertig sind; die Dauer steht im Testprotokoll.
            let start = Date()
            sleep(3)
            attach(window.screenshot(), "Import läuft")
            let busy = app.descendants(matching: .any).matching(
                NSPredicate(format: "value CONTAINS 'in Analyse' OR label CONTAINS 'in Analyse'")
            ).firstMatch
            _ = busy.waitForExistence(timeout: 60)
            print("SB_REVIEW Clips eingelesen: \(Int(Date().timeIntervalSince(start))) s")
            let done = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: busy)
            wait(for: [done], timeout: 300)
            print("SB_REVIEW Import und Analyse: \(Int(Date().timeIntervalSince(start))) s")
            let preparing = app.descendants(matching: .any).matching(
                NSPredicate(format: "value CONTAINS 'Bildsuche wird' OR label CONTAINS 'Bildsuche wird'")
            ).firstMatch
            let ready = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: preparing)
            wait(for: [ready], timeout: 300)
            print("SB_REVIEW Bildsuche bereit: \(Int(Date().timeIntervalSince(start))) s")
            attach(window.screenshot(), "Bibliothek fertig")
            let search = app.descendants(matching: .any).matching(identifier: "library.search").firstMatch
            search.click()
            search.typeText("Sonnenuntergang am Meer")
            sleep(3)
            attach(window.screenshot(), "Suche")
        }
        let clip = app.descendants(matching: .any).matching(identifier: "clip.c-cuts_50_4k_hevc").firstMatch
        let rows = app.outlines.firstMatch.cells
        if clip.exists { clip.click() } else if rows.count > 3 { rows.element(boundBy: 3).click() }
        sleep(1)
        attach(window.screenshot(), "Clip ausgewählt")
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.element(boundBy: 0)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        sleep(1)
        attach(settings.screenshot(), "Einstellungen")
    }

    @MainActor
    private func attach(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SB_REVIEW_PROJECT"] != nil, "nur für Abnahme-Fotos")
    }
}

/// Bildschirmfotos der Song-Bearbeitung. Läuft nur mit `SB_REVIEW_SONG=<Projekt>` und `SB_REVIEW_IMPORT=<Ordner>`.
final class SongReviewScreenshots: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SB_REVIEW_SONG"] != nil, "nur für Abnahme-Fotos")
    }

    @MainActor
    func testCaptureTimeline() throws {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = [
            "-SBOpenDocument", environment["SB_REVIEW_SONG"]!, "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages",
            "(de)", "-AppleLocale", "de_DE",
            "-SBImportPaths", environment["SB_REVIEW_IMPORT"]!,
        ]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        let start = Date()
        func any(_ text: String) -> XCUIElement {
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
            ).firstMatch
        }
        XCTAssertTrue(any("Wörter erkannt").waitForExistence(timeout: 420), "Gesangserkennung fehlt")
        print("SB_REVIEW Song analysiert und Gesang erkannt: \(Int(Date().timeIntervalSince(start))) s")
        sleep(2)
        attach(window.screenshot(), "Timeline gesamt")
        let timeline = app.descendants(matching: .any).matching(identifier: "timeline").firstMatch
        let canvas = timeline.descendants(matching: .group).firstMatch
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).click()
        for _ in 0..<4 { app.typeKey("+", modifierFlags: .command) }
        sleep(1)
        attach(window.screenshot(), "Timeline vergrößert")
        app.typeKey(" ", modifierFlags: [])
        sleep(3)
        app.typeKey(" ", modifierFlags: [])
        attach(window.screenshot(), "Wiedergabe")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).rightClick()
        sleep(1)
        attach(XCUIScreen.main.screenshot(), "Abschnittsmenü")
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    private func attach(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Abnahme M4 (E1, E3): leeres Projekt, Song und Clips per Import, Autopilot bis zum ersten Schnitt; danach Shot
/// tauschen, fixieren, neu würfeln. Läuft nur mit `SB_REVIEW_CUT=<Projekt>` und `SB_REVIEW_IMPORT=<Ordner>`.
final class CutReviewScreenshots: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SB_REVIEW_CUT"] != nil, "nur für Abnahme-Fotos")
    }

    @MainActor
    func testFirstCutAndShotSwap() throws {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = [
            "-SBOpenDocument", environment["SB_REVIEW_CUT"]!, "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages",
            "(de)", "-AppleLocale", "de_DE", "-SBImportPaths", environment["SB_REVIEW_IMPORT"]!,
        ]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        let start = Date()
        let canvas = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Timeline:' AND NOT (label CONTAINS ' 0 Einstellungen')")
        ).firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 600), "kein erster Schnitt")
        let video = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Vorschau des Schnitts'"))
            .firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 30), "Vorschau ohne Bild")
        print("SB_REVIEW Erster Schnitt mit Vorschau: \(Int(Date().timeIntervalSince(start))) s")
        let alert = app.sheets.firstMatch
        XCTAssertFalse(alert.exists, "Fehlermeldung sichtbar")
        sleep(2)
        attach(window.screenshot(), "Erster Schnitt")

        // Abspielen ab einem Refrain (Drittel des Songs).
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.36, dy: 0.5)).click()
        app.typeKey(" ", modifierFlags: [])
        sleep(3)
        attach(window.screenshot(), "Wiedergabe")
        app.typeKey(" ", modifierFlags: [])

        // E3: Shot wählen, Begründung, Alternative übernehmen (fixiert), neu würfeln.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.87)).click()
        let reasons = app.descendants(matching: .any).matching(identifier: "shot.reasons").firstMatch
        XCTAssertTrue(reasons.waitForExistence(timeout: 5))
        sleep(1)
        attach(window.screenshot(), "Warum dieser Clip")
        let alternative = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Alternative '")).firstMatch
        XCTAssertTrue(alternative.waitForExistence(timeout: 5))
        alternative.click()
        sleep(1)
        attach(window.screenshot(), "Alternative gewählt")
        app.typeKey("r", modifierFlags: .command)
        sleep(2)
        attach(window.screenshot(), "Neu gewürfelt")

        // Stil wechseln: Hektisch.
        app.menuButtons["cut.style"].click()
        app.menuItems["Hektisch"].click()
        sleep(2)
        attach(window.screenshot(), "Stil hektisch")
        app.typeKey("s", modifierFlags: .command)
        sleep(1)
    }

    @MainActor
    private func attach(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Abnahme M5 mit echten Modellen (nur lokal): Storyboard mit Apple Intelligence, Bildbeschreibung mit Qwen3-VL über
/// MLX im Inferenzdienst. Läuft nur mit `SB_REVIEW_AI=<Projekt mit Analyse, Clips und Schnitt>`.
final class AIReviewScreenshots: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SB_REVIEW_AI"] != nil, "nur für Abnahme-Fotos")
    }

    @MainActor
    func testStoryboardAndDescription() throws {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = [
            "-SBOpenDocument", environment["SB_REVIEW_AI"]!, "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages",
            "(de)", "-AppleLocale", "de_DE", "-ai.director.provider", "appleIntelligence", "-ai.vision.provider", "mlx",
            "-ai.autoDescribe", "NO",
        ]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        let brief = app.descendants(matching: .any).matching(identifier: "director.brief").firstMatch
        XCTAssertTrue(brief.waitForExistence(timeout: 15))
        brief.click()
        brief.typeKey("a", modifierFlags: .command)
        brief.typeText("Sommerliche Liebesgeschichte am Meer, Refrain bei Nacht, Ende im Sonnenuntergang\r")
        var start = Date()
        app.buttons["director.create"].click()
        let idea = app.descendants(matching: .any).matching(identifier: "director.idea").firstMatch
        XCTAssertTrue(idea.waitForExistence(timeout: 180), "kein Storyboard")
        print("SB_REVIEW Storyboard mit Neuschnitt: \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        sleep(2)
        attach(window.screenshot(), "Storyboard")

        let clip = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'clip.c-'"))
            .firstMatch
        XCTAssertTrue(clip.waitForExistence(timeout: 5))
        clip.click()
        let describe = app.buttons["clip.describe"]
        XCTAssertTrue(describe.waitForExistence(timeout: 5))
        start = Date()
        describe.click()
        let done = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == 'clip.describedBy' AND (label CONTAINS 'qwen3-vl' OR value CONTAINS 'qwen3-vl')")
        ).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 300), "keine Beschreibung von Qwen3-VL")
        print(
            "SB_REVIEW Beschreibung mit Qwen3-VL (inkl. Laden): \(String(format: "%.1f", Date().timeIntervalSince(start))) s"
        )
        sleep(1)
        attach(window.screenshot(), "Beschreibung")
        app.typeKey("s", modifierFlags: .command)
        sleep(1)
    }

    @MainActor
    private func attach(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// E8 (teilweise): Bildbeschreibung läuft, die App wird hart beendet und neu gestartet; die Aufgabe setzt fort und
/// übernimmt Fertiges aus dem Zwischenspeicher. Läuft nur mit `SB_REVIEW_E8=<Projekt ohne Beschreibungen>`.
final class ResumeReviewTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SB_REVIEW_E8"] != nil, "nur zur Abnahme")
    }

    @MainActor
    func testDescriptionsResumeAfterKill() throws {
        let path = ProcessInfo.processInfo.environment["SB_REVIEW_E8"]!
        func launch() -> XCUIApplication {
            let app = XCUIApplication()
            app.launchArguments = [
                "-SBOpenDocument", path, "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(de)",
                "-AppleLocale", "de_DE", "-ai.vision.provider", "appleIntelligence", "-ai.autoDescribe", "YES",
            ]
            app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
            return app
        }
        var app = launch()
        sleep(15)
        app.terminate()
        print("SB_REVIEW App nach 15 s beendet (ohne Sichern)")
        let start = Date()
        app = launch()
        let done = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'Clips beschrieben' OR value CONTAINS 'Clips beschrieben'")
        ).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 300), "Aufgabe nicht fortgesetzt")
        print("SB_REVIEW Fortgesetzt und fertig nach \(Int(Date().timeIntervalSince(start))) s: \(done.label)")
        app.typeKey("s", modifierFlags: .command)
        sleep(1)
        app.terminate()
    }
}
