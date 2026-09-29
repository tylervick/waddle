import XCTest

/// Regression test for issue #95: after a session ended in `I_Error`, the
/// error alert could not be dismissed and the app needed a force quit.
///
/// The stuck alert was SDL's own message box (`I_ErrorMsg`, titled with the
/// engine version), not the launcher's. The whole session ran inside UIKit's
/// dispatch of the tile tap, and the box's nested run loop never delivered
/// its OK action. This runs the production path -- no WADDLE_TEST_NOGUI, which
/// every other failing-session test sets to keep that box away -- for two
/// error sessions in a row, and requires both alerts to dismiss and the
/// shelf to take taps again. WADDLE_TEST_ZIP_<n> makes each session fail on
/// a zip whose WAD has a bad id (see SessionStartStateTests).
final class EngineErrorAlertDismissalTests: XCTestCase {

    @MainActor
    func testErrorAlertsDismissAfterTwoErrorSessions() throws {
        continueAfterFailure = false
        let wad = SessionStartStateTests.pwad(lumpData: Data("WADDLE".utf8))
        let badID = SessionStartStateTests.storedZip(name: "waddle-test.wad",
                                                     data: Data("X".utf8) + wad.dropFirst())
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_TEST_ZIP_1"] = badID.base64EncodedString()
        app.launchEnvironment["WADDLE_TEST_ZIP_2"] = badID.base64EncodedString()
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }

        let tile = app.buttons["playFreedoom1"]
        for session in 1...2 {
            XCTAssertTrue(tile.waitForExistence(timeout: 30), "session \(session): tile missing")
            tile.tap()

            let engineBox = app.alerts.matching(NSPredicate(format: "label BEGINSWITH 'Woof'")).firstMatch
            XCTAssertTrue(engineBox.waitForExistence(timeout: 60),
                          "session \(session): the engine's error box never appeared")
            XCTAssertTrue(engineBox.staticTexts.matching(NSPredicate(
                format: "label CONTAINS %@", "doesn't have IWAD or PWAD id")).firstMatch.exists,
                "session \(session): the engine failed, but not where the test made it fail")
            engineBox.buttons["OK"].tap()
            XCTAssertTrue(engineBox.waitForNonExistence(timeout: 10),
                          "session \(session): the engine's error box did not dismiss on OK")

            let launcherAlert = app.alerts["Couldn't run this game"]
            XCTAssertTrue(launcherAlert.waitForExistence(timeout: 10),
                          "session \(session): the launcher's error alert never appeared")
            launcherAlert.buttons["OK"].tap()
            XCTAssertTrue(launcherAlert.waitForNonExistence(timeout: 10),
                          "session \(session): the launcher's error alert did not dismiss on OK")

            XCTAssertTrue(tile.waitForHittable(timeout: 10),
                          "session \(session): the shelf does not take taps after the alerts")
        }
    }
}

private extension XCUIElement {
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists && isHittable { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
