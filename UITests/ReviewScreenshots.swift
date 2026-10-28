import XCTest

/// Bildschirmfotos für die Abnahme. Läuft nur, wenn `SB_REVIEW_PROJECT` gesetzt ist
/// (bei xcodebuild: `TEST_RUNNER_SB_REVIEW_PROJECT=<Pfad>`); die Bilder landen als Anhänge im Ergebnisbündel.
final class ReviewScreenshots: XCTestCase {
    @MainActor
    func testCaptureProjectWindow() throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try XCTUnwrap(environment["SB_REVIEW_PROJECT"], "SB_REVIEW_PROJECT nicht gesetzt")
        let app = XCUIApplication()
        app.launchArguments = ["-SBOpenDocument", path, "-ApplePersistenceIgnoreState", "YES"]
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
