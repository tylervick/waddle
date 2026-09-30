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
        let filesScreen = app.descendants(matching: .any).matching(identifier: "filesScreen").firstMatch
        XCTAssertFalse(filesScreen.buttons["importButton"].exists, "Files must not carry its own import button")
        XCTAssertFalse(app.navigationBars["Files"].buttons["importButton"].exists, "…nor in its toolbar")
    }

    /// Swipe-to-delete on a tall Files row. The assertion is that the swipe
    /// reveals a Delete action at all; the screenshot is for a human, because
    /// the *shape* of that action is what
    /// `docs/learnings/ios26-list-swipe-actions-row-height.md` is about and
    /// no assertion can see it (issue #244 re-measured it on iOS 27).
    ///
    /// Bundled rows are `deleteDisabled`, so the only rows with a swipe
    /// action are imported ones: this needs a real WAD provisioned by
    /// `Scripts/provision-test-wads.sh`, and skips without it, exactly as
    /// the DOOM2 gate in `DemoLoopReplayTests` does. Swipes the list CELL:
    /// the row's combined accessibility element does not carry the gesture.
    @MainActor
    func testSwipingATallImportedRowRevealsDelete() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["importButton"].waitForExistence(timeout: 10), "Add missing from the shelf")
        openFiles(app)

        let rowID = "fileRow-SCYTHE.WAD"
        let row = app.descendants(matching: .any).matching(identifier: rowID).firstMatch
        guard row.waitForExistence(timeout: 10) else {
            throw XCTSkip("SCYTHE.WAD not provisioned into the simulator — see " +
                          "Scripts/provision-test-wads.sh. Skipping.")
        }
        scrollTo(row, in: app)
        let cell = app.cells.containing(.staticText, identifier: rowID).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "no list cell contains the SCYTHE.WAD row")
        cell.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "swiping an imported row revealed no Delete action")
        Thread.sleep(forTimeInterval: 1) // let the reveal animation settle before the shot

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "files-row-swipe-ios\(UIDevice.current.systemVersion)"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
