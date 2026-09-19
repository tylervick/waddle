import XCTest

/// Regression coverage for C1: Restore (Settings → Hidden Games) has to reach
/// the shelf even though Settings is presented as a sheet, whose dismissal
/// never re-fires the shelf's own `.onAppear`.
final class HiddenGamesScreenTests: XCTestCase {
    @MainActor
    func testRestoreReturnsTheTileToTheShelf() {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launch()

        let tile = app.buttons["playFreedoom1"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "playFreedoom1 tile missing from a fresh shelf")
        tile.press(forDuration: 1.0)
        let hide = app.buttons["Hide from Shelf"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "Hide from Shelf missing from the context menu")
        hide.tap()

        XCTAssertFalse(tile.waitForExistence(timeout: 2), "tile still on the shelf after hiding it")

        let gear = app.buttons["touchSchemeMenu"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "gear missing from the shelf")
        gear.tap()
        let hiddenGamesButton = app.buttons["hiddenGamesButton"]
        XCTAssertTrue(hiddenGamesButton.waitForExistence(timeout: 5), "Hidden Games row missing from Settings")
        hiddenGamesButton.tap()
        let hiddenGamesScreen = app.descendants(matching: .any).matching(identifier: "hiddenGamesScreen").firstMatch
        XCTAssertTrue(hiddenGamesScreen.waitForExistence(timeout: 5), "Hidden Games screen never appeared")

        let restore = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'restore-'")).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 5), "no Restore button for the hidden game")
        restore.tap()

        // Scoped to this navigation bar, not `app.navigationBars.buttons`
        // app-wide: the shelf sits underneath this sheet and its own gear
        // button is also labeled "Settings", so an unscoped query matches
        // both it and this screen's actual back button.
        let settingsBack = app.navigationBars["Hidden Games"].buttons["Settings"]
        XCTAssertTrue(settingsBack.waitForExistence(timeout: 5), "no way back to the Settings root")
        settingsBack.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Settings Done missing")
        done.tap()

        // The regression this test exists for: restoring a game from inside
        // the Settings sheet must reach the shelf on dismissal, even though
        // dismissing a sheet never re-runs the presenter's `onAppear`.
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "restored tile never reappeared on the shelf")
    }
}
