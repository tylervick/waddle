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
        openShelfSettings(in: app)
        let firstRow = app.descendants(matching: .any).matching(identifier: "touchSchemePicker").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "Settings never opened")
        assertBelow(band, app.navigationBars["Settings"], "Settings' bar", in: app)
        assertBelow(band, firstRow, "Settings' first row", in: app)
        XCTAssertLessThanOrEqual(shelfBar.frame.maxY, band.minY + 0.5, "\(shelfBar.frame)")
        XCTAssertTrue(app.buttons["playFreedoom1"].isHittable, "the shelf is covered while Settings is open")
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

        openShelfSettings(in: app)
        let settingsBar = app.navigationBars["Settings"]
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 10), "Settings never opened")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(settingsBar.frame.minY, window.midY - 20,
                          "flat, Settings is a sheet from the top of the window: \(settingsBar.frame)")

        // One screen in, so the move is seen to keep it: the sheet's Files
        // must be the lower half's Files, not Settings again.
        app.buttons["filesButton"].tap()
        let files = app.descendants(matching: .any).matching(identifier: "filesScreen").firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 10), "Files never opened in the sheet")

        notify_post("com.tylervick.waddle.test.half-open-toggle")
        let band = try foldBand(in: app)
        XCTAssertTrue(waitUntil { files.exists && files.frame.minY >= band.maxY - 0.5 },
                      "bent, Files should have moved below the fold, still pushed: "
                      + "Files \(files.exists ? "\(files.frame)" : "is gone"), band \(band)")
        XCTAssertLessThanOrEqual(try shelfScrollView(in: app).frame.maxY, band.minY + 0.5)
        XCTAssertTrue(app.buttons["playFreedoom1"].isHittable, "the shelf is still covered")
    }

    /// A fold keeps the screen pushed inside the panel, in both directions:
    /// Settings > Files in the lower half is Files in the panel when the
    /// device is opened flat, and Files again below the fold when it is
    /// bent. The two arrangements are two view trees, and the path used to
    /// be each tree's own (review of pull request 461).
    @MainActor
    func testAFoldKeepsTheScreenPushedInsideThePanel() throws {
        let app = launchLauncher(halfOpen: "1")
        let band = try foldBand(in: app)
        openShelfSettings(in: app)
        // Settings' first row says it opened. Files is further down, and on
        // a bent iPhone Duo the lower half is too short for the lazy list
        // to have built that row yet, so it is scrolled to.
        let firstRow = app.buttons["touchSchemePicker"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "Settings never opened")
        let settingsList = app.collectionViews.containing(.button, identifier: "touchSchemePicker").firstMatch
        scrollTo(app.buttons["filesButton"], in: app, swiping: settingsList)
        app.buttons["filesButton"].tap()
        let files = app.descendants(matching: .any).matching(identifier: "filesScreen").firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 10), "Files never opened")
        assertBelow(band, files, "Files", in: app)

        notify_post("com.tylervick.waddle.test.half-open-toggle")
        XCTAssertTrue(waitUntil { !app.otherElements["launcherLowerHalf"].exists },
                      "the launcher stayed in two halves after opening flat")
        XCTAssertTrue(waitUntil { files.exists && files.frame.minY < band.minY },
                      "flat, the panel should still be on Files: "
                      + (files.exists ? "\(files.frame)" : "Files is gone"))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "touchSchemePicker").firstMatch.exists,
                       "flat, the panel went back to Settings' first screen")

        notify_post("com.tylervick.waddle.test.half-open-toggle")
        let again = try foldBand(in: app)
        XCTAssertTrue(waitUntil { files.exists && files.frame.minY >= again.maxY - 0.5 },
                      "bent again, the lower half should still be on Files: "
                      + (files.exists ? "\(files.frame)" : "Files is gone"))

        // And back out the way a player goes: Files' back button is Settings.
        // The Settings it reaches is a list built again at its top, so its
        // Files row is scrolled to, as on the way in.
        app.buttons.matching(identifier: "BackButton").firstMatch.tap()
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "back from Files did not reach Settings")
        scrollTo(app.buttons["filesButton"], in: app, swiping: settingsList)
    }

    /// A save warning that is up when the device is opened flat, or bent, is
    /// still up afterwards, and its answer still applies. It is a dialog,
    /// which goes down with the tree that presented it, so the next tree
    /// puts it up again; before the fix the edit it guarded was dropped
    /// without a word (review of pull request 461).
    ///
    /// A game with a base to change and a save needs two launches
    /// (`launchWithASavedCopy`).
    ///
    /// Each check waits for the swap to settle first (`waitForPanelSwap`).
    /// Asked while the old tree's dialog is still on its way out, XCUITest
    /// can find that dialog, and its `isHittable` records a failure ("the
    /// activation point is invalid") instead of answering false. On an iPad
    /// Pro 13-inch that failed the test on a busy simulator while the app,
    /// by its own log, put the warning up again 0.9 s after the fold
    /// (issue #520).
    ///
    /// On an iPad the warning found after opening flat used to be able to
    /// be the lower half's, orphaned over the shelf, and the test passed
    /// with the column's own warning switched off. The root now takes the
    /// departing tree's dialog down itself (`LauncherFold.dismissDialogs`);
    /// with the column's switched off this fails at the flat check, 3 runs
    /// in 3.
    @MainActor
    func testAFoldKeepsTheSaveWarningUpAndItsAnswerStillApplies() throws {
        let copyName = Self.savedCopyName
        let app = launchWithASavedCopy(environment: ["WADDLE_TEST_HALF_OPEN": "1"])
        _ = try foldBand(in: app)
        let tile = app.buttons["game-\(copyName)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "the copy's tile is missing")
        tile.press(forDuration: 1.0)
        app.buttons["Details"].tap()
        XCTAssertTrue(app.navigationBars[copyName].waitForExistence(timeout: 10), "the copy's page never opened")

        // Change its base: with a save, that asks first.
        let picker = app.buttons["basePicker"]
        let changeAnyway = raiseTheSaveWarning(in: app, picker: picker)

        // Open flat: the warning is up again, over the panel, with the
        // picker under it still on the base it asks about.
        notify_post("com.tylervick.waddle.test.half-open-toggle")
        XCTAssertTrue(waitUntil { !app.otherElements["launcherLowerHalf"].exists },
                      "the launcher stayed in two halves after opening flat")
        XCTAssertTrue(waitForPanelSwap(in: app), "the swap of panel trees never settled")
        XCTAssertTrue(waitUntil(timeout: 12) { changeAnyway.exists && changeAnyway.isHittable },
                      "opened flat, the save warning was dropped")
        XCTAssertTrue(picker.label.contains("Freedoom Phase 2"),
                      "opened flat, the picker under the warning is back on the old base: \(picker.label)")

        // Bend: up again, and this time it is answered.
        notify_post("com.tylervick.waddle.test.half-open-toggle")
        _ = try foldBand(in: app)
        XCTAssertTrue(waitForPanelSwap(in: app), "the swap of panel trees never settled")
        XCTAssertTrue(waitUntil(timeout: 12) { changeAnyway.exists && changeAnyway.isHittable },
                      "bent again, the save warning was dropped")
        changeAnyway.tap()
        assertStoredBase(of: Self.savedCopyName, is: "Freedoom Phase 2", after: changeAnyway, in: app)
    }

    /// The shelf's own dialogs are on a tree that a change of pose leaves in
    /// place, and they stay up across it: here a tile's Continue / New Game
    /// / Details. Taking down the dialog a departing panel tree left behind
    /// once took these down too, and dropped them (review of pull request
    /// 524). Started flat on the seam so the first change is a bend.
    @MainActor
    func testAPoseChangeLeavesTheShelfsTileActionsUp() throws {
        let app = launchWithASavedCopy(environment: ["WADDLE_TEST_HALF_OPEN": "0"])
        let tile = app.buttons["game-\(Self.savedCopyName)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "the copy's tile is missing")
        tile.tap()
        let continueAction = app.buttons["continueAction"]
        XCTAssertTrue(continueAction.waitForExistence(timeout: 5), "the tile's actions never came up")

        notify_post("com.tylervick.waddle.test.half-open-toggle")
        _ = try foldBand(in: app)
        assertStaysUp(continueAction, "bent, the tile's actions were dropped", in: app)

        notify_post("com.tylervick.waddle.test.half-open-toggle")
        XCTAssertTrue(waitUntil { !app.otherElements["launcherLowerHalf"].exists },
                      "the launcher stayed in two halves after opening flat")
        assertStaysUp(continueAction, "opened flat, the tile's actions were dropped", in: app)
    }

    /// The same when the tile is the hero's game: bent, the Continue hero
    /// steps aside and its game is a tile in the grid; opened flat, the hero
    /// comes back and the tile leaves the grid. The game's actions stay up
    /// through flat, bent and flat again, and point at whichever view stands
    /// for the game: the tile while bent, the hero while flat, its arrow on
    /// that view's edge as when first presented. Before the popover was laid
    /// out again after the move, its tip after opening flat was at y 295
    /// inside the hero on an iPhone 18 Pro and at y 403.7, 30 pt below the
    /// hero, on an iPhone Duo (re-review of pull request 536). The copy in
    /// `testAPoseChangeLeavesTheShelfsTileActionsUp` is never the hero, so it
    /// could not see a dialog that left with its tile (review of pull
    /// request 536).
    @MainActor
    func testAPoseChangeKeepsTheHeroGamesActionsUpAndOnIt() throws {
        let app = XCUIApplication()
        app.provideFreedoom()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        // A save for Freedoom Phase 1, marked played: the hero's game, and a
        // tile that taps to its actions when the hero is not drawn.
        app.launchEnvironment["WADDLE_TEST_SUSPEND_SAVE"] = Self.placeholderSuspendSave
        app.launchEnvironment["WADDLE_TEST_HALF_OPEN"] = "0"
        app.launch()
        XCTAssertTrue(waitForShelf(in: app), "the shelf never appeared")
        let hero = app.descendants(matching: .any).matching(identifier: "continueHero").firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 10), "flat, there is no Continue hero")

        notify_post("com.tylervick.waddle.test.half-open-toggle")
        _ = try foldBand(in: app)
        let tile = app.buttons["playFreedoom1"]
        XCTAssertTrue(tile.waitForExistence(timeout: 8), "bent, the hero's game is not a tile")
        tile.tap()
        let continueAction = app.buttons["continueAction"]
        XCTAssertTrue(continueAction.waitForExistence(timeout: 5), "the tile's actions never came up")
        assertArrowPoints(at: tile, in: app, "bent, the hero's game as a tile")

        notify_post("com.tylervick.waddle.test.half-open-toggle")
        XCTAssertTrue(waitUntil { !app.otherElements["launcherLowerHalf"].exists },
                      "the launcher stayed in two halves after opening flat")
        assertStaysUp(continueAction, "opened flat, the hero's game's actions were dropped", in: app)
        assertArrowPoints(at: hero, in: app, "flat, the hero", timeout: 8)

        notify_post("com.tylervick.waddle.test.half-open-toggle")
        _ = try foldBand(in: app)
        assertStaysUp(continueAction, "bent again, the hero's game's actions were dropped", in: app)
        assertArrowPoints(at: app.buttons["playFreedoom1"], in: app, "bent again, the tile", timeout: 8)

        notify_post("com.tylervick.waddle.test.half-open-toggle")
        XCTAssertTrue(waitUntil { !app.otherElements["launcherLowerHalf"].exists },
                      "the launcher stayed in two halves after opening flat again")
        assertStaysUp(continueAction, "opened flat again, the hero's game's actions were dropped", in: app)
    }

    /// 64 bytes of "x", raw-deflate compressed and base64 encoded, as
    /// `WADDLE_TEST_SUSPEND_SAVE` takes a save: a file the shelf counts,
    /// which nothing here loads (the same bytes `DuoLayoutSweepTests` uses).
    static let placeholderSuspendSave = "q6igDAAA"

    /// The same for the launcher's alert after a session that failed: the
    /// one place the player is told why, and it is the shelf's.
    @MainActor
    func testAPoseChangeLeavesTheEngineErrorAlertUp() throws {
        let wad = SessionStartStateTests.pwad(lumpData: Data("WADDLE".utf8))
        let badID = SessionStartStateTests.storedZip(name: "waddle-test.wad",
                                                     data: Data("X".utf8) + wad.dropFirst())
        let app = XCUIApplication()
        app.provideFreedoom()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launchEnvironment["WADDLE_TEST_HALF_OPEN"] = "0"
        app.launchEnvironment["WADDLE_TEST_ZIP_1"] = badID.base64EncodedString()
        app.launch()
        XCTAssertTrue(waitForShelf(in: app, timeout: 60), "the shelf never appeared")
        let tile = app.buttons["playFreedoom1"]
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "the tile is missing")
        tile.tap()
        let engineBox = app.alerts.matching(NSPredicate(format: "label BEGINSWITH 'Woof'")).firstMatch
        XCTAssertTrue(engineBox.waitForExistence(timeout: 60), "the engine's error box never appeared")
        engineBox.buttons["OK"].tap()
        let launcherAlert = app.alerts["Couldn't run this game"]
        XCTAssertTrue(launcherAlert.waitForExistence(timeout: 10), "the launcher's error alert never appeared")

        notify_post("com.tylervick.waddle.test.half-open-toggle")
        _ = try foldBand(in: app)
        assertStaysUp(launcherAlert, "bent, the launcher's error alert was dropped", in: app)
        launcherAlert.buttons["OK"].tap()
        XCTAssertTrue(launcherAlert.waitForNonExistence(timeout: 10), "the error alert did not dismiss on OK")
    }

    // MARK: helpers

    /// Once the swap has settled, `element` is up and stays up: a dialog
    /// taken down by mistake is gone within its dismissal, about 0.3 s.
    @MainActor
    func assertStaysUp(_ element: XCUIElement, _ message: String, in app: XCUIApplication,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForPanelSwap(in: app), "the swap of panel trees never settled", file: file, line: line)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            guard element.exists else { return XCTFail(message, file: file, line: line) }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(element.exists, message, file: file, line: line)
    }

    /// What the store says the game's base is, read from a fresh launch: a
    /// waiting warning already puts its choice in the picker, so the
    /// picker on the page that asked says nothing about whether the answer
    /// was applied (review of pull request 524).
    @MainActor
    func assertStoredBase(of gameName: String, is base: String, after answer: XCUIElement,
                          in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(answer.waitForNonExistence(timeout: 5), "the warning did not go when answered",
                      file: file, line: line)
        app.terminate()
        let fresh = XCUIApplication()
        fresh.provideFreedoom()
        fresh.launch()
        XCTAssertTrue(waitForShelf(in: fresh), "the shelf never appeared",
                      file: file, line: line)
        openGamePage(fresh, tile: "game-\(gameName)", file: file, line: line)
        let picker = fresh.buttons["basePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "no base picker on the page", file: file, line: line)
        XCTAssertTrue(picker.label.contains(base),
                      "the answer to the warning was not applied: the stored base reads \(picker.label)",
                      file: file, line: line)
    }

    static let savedCopyName = "Freedoom Phase 1 copy"

    /// A game with a base to change and a save: one launch to duplicate
    /// Freedoom Phase 1, one to give the copy a save
    /// (`WADDLE_TEST_SEED_SAVE_FOR`). Returns the second, on the shelf.
    @MainActor
    func launchWithASavedCopy(environment: [String: String] = [:],
                              beforeFirstPage: (XCUIApplication) -> Void = { _ in }) -> XCUIApplication {
        let first = XCUIApplication()
        first.provideFreedoom()
        first.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        first.launch()
        beforeFirstPage(first)
        openGamePage(first, tile: "playFreedoom1")
        scrollTo(first.buttons["duplicateButton"], in: first)
        first.buttons["duplicateButton"].tap()
        XCTAssertTrue(first.buttons["game-\(Self.savedCopyName)"].waitForExistence(timeout: 5),
                      "the copy never appeared")
        first.terminate()

        let app = XCUIApplication()
        app.provideFreedoom()
        app.launchEnvironment["WADDLE_TEST_SEED_SAVE_FOR"] = Self.savedCopyName
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launch()
        XCTAssertTrue(waitForShelf(in: app), "the shelf never appeared")
        return app
    }

    /// Picks Freedoom Phase 2 as the open page's base; the page has a save,
    /// so that asks first. Returns the warning's Change Anyway.
    @MainActor
    func raiseTheSaveWarning(in app: XCUIApplication, picker: XCUIElement,
                             file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "no base picker on the copy's page", file: file, line: line)
        picker.tap()
        app.buttons["Freedoom Phase 2"].firstMatch.tap()
        let changeAnyway = app.buttons.matching(identifier: "changeAnywayAction").firstMatch
        XCTAssertTrue(changeAnyway.waitForExistence(timeout: 8), "the save warning never came up", file: file, line: line)
        return changeAnyway
    }

    /// Waits until the panel's trees have finished swapping and the new one
    /// may present: the root shows `panelSwapSettling` while they have not.
    /// Call it once the change that started the swap is on screen.
    @MainActor
    func waitForPanelSwap(in app: XCUIApplication, timeout: TimeInterval = 8) -> Bool {
        let settling = app.otherElements["panelSwapSettling"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !settling.exists { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !settling.exists
    }

    @MainActor
    private func launchLauncher(halfOpen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.provideFreedoom()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launchEnvironment["WADDLE_TEST_HALF_OPEN"] = halfOpen
        app.launch()
        XCTAssertTrue(waitForShelf(in: app), "the shelf never appeared")
        return app
    }

    /// Waits for the shelf by one of its tiles: Freedoom Phase 1's, or any
    /// game's. Not by the bar's Add, which a bent iPhone Duo moves under a
    /// More button with Settings: the upper half is too short a window for
    /// the bar to hold them (issue #541).
    @MainActor
    func waitForShelf(in app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        app.buttons.matching(NSPredicate(format: "identifier == 'playFreedoom1' OR identifier BEGINSWITH 'game-'"))
            .firstMatch.waitForExistence(timeout: timeout)
    }

    /// Opens Settings from the shelf's bar: the gear where it is in the bar,
    /// and through the bar's More where the system has moved it there, as on
    /// a bent iPhone Duo (issue #541).
    @MainActor
    func openShelfSettings(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let gear = app.buttons["touchSchemeMenu"]
        let more = app.buttons["BottomOverflowBarButtonItem"]
        guard waitUntil(timeout: 10, { gear.exists || more.exists }) else {
            return XCTFail("the shelf's bar has neither Settings nor More", file: file, line: line)
        }
        if gear.exists {
            gear.tap()
            return
        }
        more.tap()
        let item = app.buttons.matching(NSPredicate(format: "identifier == 'touchSchemeMenu' OR label == 'Settings'"))
            .firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the bar's More has no Settings", file: file, line: line)
        item.tap()
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
