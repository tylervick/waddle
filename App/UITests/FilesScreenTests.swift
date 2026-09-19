import XCTest

/// Settings → Files (spec §3.4): the bundled base games appear under
/// "Base games" with their on-disk filename and Bundled status, and there is no
/// import button here — Add lives on the shelf.
final class FilesScreenTests: XCTestCase {
    @MainActor
    func testFilesShowsGroupedBundledBaseGames() {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["importButton"].waitForExistence(timeout: 10), "Add missing from the shelf")
        openFiles(app)

        XCTAssertTrue(app.staticTexts["Base games"].waitForExistence(timeout: 5), "grouped section header missing")
        let row = app.descendants(matching: .any).matching(identifier: "fileRow-freedoom1.wad").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "bundled freedoom1.wad row missing")
        XCTAssertTrue(row.label.contains("Bundled"), "row does not surface bundled status; label = '\(row.label)'")
        XCTAssertTrue(row.label.contains("Used by Freedoom Phase 1"), "row does not say who uses it; label = '\(row.label)'")
        XCTAssertFalse(app.buttons["importButton"].exists, "Files must not carry its own import button")
    }
}
