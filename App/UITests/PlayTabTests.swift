import XCTest

final class PlayTabTests: XCTestCase {
    @MainActor
    func testBaseGameDetailControlsOverridePersists() {
        let app = XCUIApplication()
        // Reset so the base game starts with no override (the "Default" state).
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launch()
        let tile = app.buttons["playFreedoom1"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))

        // Open Details and set the Controls override to MODERN. Modern is
        // distinct from the global default (Classic), so a persisted Modern is
        // unambiguous — the no-override label renders as "Default (Classic)",
        // which must NOT be mistaken for a saved selection.
        tile.press(forDuration: 1.0)               // context menu
        app.buttons["Details"].tap()
        let picker = app.buttons["detailSchemePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["Modern"].tap()

        // Dismiss the detail sheet by dragging it down from its navigation bar,
        // and confirm it's actually gone (the picker no longer exists).
        let navBar = app.navigationBars.firstMatch
        XCTAssertTrue(navBar.waitForExistence(timeout: 5))
        navBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.buttons["detailSchemePicker"].waitForNonExistence(timeout: 5),
                      "detail sheet did not dismiss")

        // Reopen Details — the override must have persisted as Modern.
        tile.press(forDuration: 1.0)
        app.buttons["Details"].tap()
        let reopened = app.buttons["detailSchemePicker"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertTrue(reopened.label.contains("Modern"),
                      "scheme override did not persist across reopen; picker label = '\(reopened.label)'")
    }
}
