import XCTest

final class LibraryTabTests: XCTestCase {
    /// The reworked Library tab is a grouped file manager: bundled base
    /// games appear under "Base Games" showing on-disk filename and a
    /// Bundled status, and the toolbar still exposes the import button.
    @MainActor
    func testLibraryShowsGroupedBundledBaseGames() {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launch()

        // iOS 26 TabView: switch via the button LABEL, assert via the pane id.
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.otherElements["libraryTab"].waitForExistence(timeout: 10))

        XCTAssertTrue(app.staticTexts["Base Games"].waitForExistence(timeout: 5),
                      "grouped section header missing")
        let row = app.descendants(matching: .any)
            .matching(identifier: "libraryRow-freedoom1.wad").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "bundled freedoom1.wad row missing")
        XCTAssertTrue(row.label.contains("Bundled"),
                      "row does not surface bundled status; label = '\(row.label)'")
        XCTAssertTrue(app.buttons["importButton"].exists)
    }
}
