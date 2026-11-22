import XCTest
import notify

/// The launcher on a half-open iPhone Duo (issue #429): the shelf above the
/// fold and the panel below it, the way `HalfOpenLayoutTests` shows the
/// session's picture above and its controls below.
///
/// No simulator in CI has a hinge, so this uses the session's own seam:
/// `WADDLE_TEST_HALF_OPEN` stands in for a partly open hinge and a 40 pt band
/// across the middle of the window, and the Darwin notification flips it.
/// Everything downstream of that reading is the shipping layout. That a real
/// Duo reports those two things, and what the screen then looks like, is the
/// sweep's job (`Scripts/duo-layout-sweep.sh run half-open`): a geometry test
/// cannot see the screen.
///
/// An extension of `PlayTabTests`, in its own file: these are tests of the
/// shelf, and that class is in the set a pull request runs
/// (`.github/workflows/ui-tests.yml`), which a new class would not be.
extension PlayTabTests {

    /// Half open: the shelf's frame ends at or above the band and the
    /// panel's begins at or below it, for the resting page, for Settings and
    /// for a game's page. Then flat and half open again without a relaunch.
    @MainActor
    func testHalfOpenTheShelfIsAboveTheFoldAndThePanelBelowIt() throws {
        let app = launchLauncher(halfOpen: "1")
        let band = try foldBand(in: app)
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(band.height, 40, accuracy: 0.5, "the seam's band is 40 pt: \(band)")
        XCTAssertGreaterThan(band.minY, window.height * 0.25, "\(band) in \(window)")
        XCTAssertLessThan(band.maxY, window.height * 0.75, "\(band) in \(window)")

        // The shelf: its bar, and the scroll view that holds its tiles.
        let shelfBar = app.navigationBars["Waddle"]
        XCTAssertLessThanOrEqual(shelfBar.frame.maxY, band.minY + 0.5, "\(shelfBar.frame)")
        let shelf = try shelfScrollView(in: app)
        XCTAssertLessThanOrEqual(shelf.frame.maxY, band.minY + 0.5,
                                 "the shelf crosses the fold: \(shelf.frame), band \(band)")
        XCTAssertGreaterThan(shelf.frame.height, 100, "the shelf has no room to scroll in: \(shelf.frame)")

        // Nothing open: the lower half is the page of the game to play next,
        // with its title, Play and the first row under them in sight.
        let page = app.descendants(matching: .any).matching(identifier: "gamePage").firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10), "the lower half is empty with nothing open")
        assertBelow(band, page, "the resting page", in: app)
        XCTAssertFalse(app.buttons["panelDoneButton"].exists, "the resting page has nothing to go back to")
        for (element, what) in [(app.buttons["gameNameButton"], "the page's title"),
                                (app.buttons["playButton"], "Play"),
                                (app.staticTexts["Base"].firstMatch, "the first row under them")] {
            XCTAssertTrue(element.waitForExistence(timeout: 5), "\(what) is missing from the resting page")
            assertBelow(band, element, what, in: app)
        }

        // Settings opens in the lower half, not as a sheet over the window.
        app.buttons["touchSchemeMenu"].tap()
        let firstRow = app.descendants(matching: .any).matching(identifier: "touchSchemePicker").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "Settings never opened")
        assertBelow(band, app.navigationBars["Settings"], "Settings' bar", in: app)
        assertBelow(band, firstRow, "Settings' first row", in: app)
        XCTAssertLessThanOrEqual(shelfBar.frame.maxY, band.minY + 0.5, "\(shelfBar.frame)")
        XCTAssertTrue(app.buttons["importButton"].isHittable, "the shelf is covered while Settings is open")
        app.navigationBars["Settings"].buttons["Done"].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 5), "closing Settings did not bring the resting page back")

        // A game's page, from its tile in the upper half.
        let phase2 = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Freedoom Phase 2'")).firstMatch
        XCTAssertTrue(phase2.waitForExistence(timeout: 5), "Phase 2 tile missing")
        phase2.press(forDuration: 1.0)
        app.buttons["Details"].tap()
        let phase2Bar = app.navigationBars["Freedoom Phase 2"]
        XCTAssertTrue(phase2Bar.waitForExistence(timeout: 10), "the game's page never opened")
        assertBelow(band, phase2Bar, "the game page's bar", in: app)
        assertBelow(band, page, "the game's page", in: app)
        XCTAssertTrue(app.buttons["panelDoneButton"].exists, "an opened page needs its Done")
        XCTAssertLessThanOrEqual(try shelfScrollView(in: app).frame.maxY, band.minY + 0.5)

        // Open flat: the halves go, and the page is where a flat phone has
        // an open panel, over the whole window.
        notify_post("com.tylervick.waddle.test.half-open-toggle")
        XCTAssertTrue(waitUntil { !app.otherElements["launcherLowerHalf"].exists },
                      "the launcher stayed in two halves after opening flat")
        XCTAssertTrue(waitUntil { phase2Bar.exists && phase2Bar.frame.minY < band.minY },
                      "flat, the open page should be back over the window: \(phase2Bar.frame)")

        // And half open again, with the same page still open.
        notify_post("com.tylervick.waddle.test.half-open-toggle")
        let again = try foldBand(in: app)
        XCTAssertTrue(waitUntil { phase2Bar.exists && phase2Bar.frame.minY >= again.maxY - 0.5 },
                      "bent again, the page should be below the fold: \(phase2Bar.frame), band \(again)")
        XCTAssertLessThanOrEqual(try shelfScrollView(in: app).frame.maxY, again.minY + 0.5)
    }

    /// Without the pose the panel is where it is today: on a phone, Settings
    /// is a sheet over the window and nothing is parted. Bending the device
    /// under that sheet moves it to the lower half.
    @MainActor
    func testFlatNothingIsPartedAndBendingMovesAnOpenSheetBelowTheFold() throws {
        let app = launchLauncher(halfOpen: "0")
        XCTAssertFalse(app.otherElements["launcherUpperHalf"].exists, "the launcher is parted while flat")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "gamePage").firstMatch.exists,
                       "a game's page is up with nothing open")

        app.buttons["touchSchemeMenu"].tap()
        let settingsBar = app.navigationBars["Settings"]
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 10), "Settings never opened")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(settingsBar.frame.minY, window.midY - 20,
                          "flat, Settings is a sheet from the top of the window: \(settingsBar.frame)")

        notify_post("com.tylervick.waddle.test.half-open-toggle")
        let band = try foldBand(in: app)
        XCTAssertTrue(waitUntil { settingsBar.exists && settingsBar.frame.minY >= band.maxY - 0.5 },
                      "bent, Settings should have moved below the fold: \(settingsBar.frame), band \(band)")
        XCTAssertLessThanOrEqual(try shelfScrollView(in: app).frame.maxY, band.minY + 0.5)
        XCTAssertTrue(app.buttons["importButton"].isHittable, "the shelf is still covered")
    }

    // MARK: helpers

    @MainActor
    private func launchLauncher(halfOpen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launchEnvironment["WADDLE_TEST_HALF_OPEN"] = halfOpen
        app.launch()
        XCTAssertTrue(app.buttons["importButton"].waitForExistence(timeout: 30), "the shelf never appeared")
        return app
    }

    /// The band between the two halves, from the root's two corner markers:
    /// one at the bottom of the upper half, one at the top of the lower.
    @MainActor
    private func foldBand(in app: XCUIApplication) throws -> CGRect {
        let upper = app.otherElements["launcherUpperHalf"], lower = app.otherElements["launcherLowerHalf"]
        XCTAssertTrue(upper.waitForExistence(timeout: 10), "the launcher never parted")
        XCTAssertTrue(lower.waitForExistence(timeout: 5), "the launcher has no lower half")
        let top = upper.frame.maxY, bottom = lower.frame.minY
        guard bottom > top else {
            XCTFail("the halves overlap: \(upper.frame) and \(lower.frame)")
            throw XCTSkip("no band to measure against")
        }
        let window = app.windows.firstMatch.frame
        return CGRect(x: window.minX, y: top, width: window.width, height: bottom - top)
    }

    /// The shelf's scrolling area, found by a tile inside it.
    @MainActor
    private func shelfScrollView(in app: XCUIApplication) throws -> XCUIElement {
        let scroll = app.scrollViews.containing(.button, identifier: "playFreedoom1").firstMatch
        if scroll.exists { return scroll }
        let collection = app.collectionViews.containing(.button, identifier: "playFreedoom1").firstMatch
        XCTAssertTrue(collection.exists, "the shelf's scroll view could not be found")
        return collection
    }

    @MainActor
    private func assertBelow(_ band: CGRect, _ element: XCUIElement, _ what: String, in app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        let frame = element.frame, window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(frame.minY, band.maxY - 0.5,
                                    "\(what) is not below the fold: \(frame), band \(band)", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, window.maxY + 0.5,
                                 "\(what) runs off the window: \(frame)", file: file, line: line)
    }

    private func waitUntil(timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }
}
