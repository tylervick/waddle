import XCTest

/// A tile's Continue / New Game / Details actions point at that tile.
///
/// On iOS 26 and later a confirmation dialog on an iPhone is a popover with
/// an arrow, anchored to the view the modifier is attached to. The shelf
/// attached its one dialog to the whole screen, so every tile's actions came
/// up in the same place at the top of the shelf, their arrow pointing at the
/// screen's middle and at no tile (TestFlight feedback on build 323, issue
/// 532). This measures the live popover against the tapped tile's frame: the
/// arrow's edge of the popover has to touch the tile, for a tile in each
/// column, before and after the shelf scrolls.
///
/// An extension of `PlayTabTests`, in its own file, so it runs in the set a
/// pull request runs (`.github/workflows/ui-tests.yml`).
extension PlayTabTests {

    @MainActor
    func testATilesActionsPointAtThatTile() throws {
        let app = XCUIApplication()
        app.provideFreedoom()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        // Ten copies of Freedoom Phase 1 and a save for every game: a shelf
        // of six rows on a phone, every tile tapping to its actions.
        app.launchEnvironment["WADDLE_TEST_FILL_SHELF"] = "10"
        app.launch()
        XCTAssertTrue(app.buttons["importButton"].waitForExistence(timeout: 30), "the shelf never appeared")

        // The first row, one tile in each column, with the shelf at rest.
        assertActionsPoint(at: app.buttons["playFreedoom1"], in: app, "first row, left")
        assertActionsPoint(at: app.buttons["game-Freedoom Phase 2"], in: app, "first row, right")

        // The last row, after scrolling to it: the defect put the popover in
        // the same place wherever the shelf had scrolled to.
        let lastLeft = app.buttons["game-Shelf 9"], lastRight = app.buttons["game-Shelf 10"]
        scrollTo(lastRight, in: app)
        XCTAssertLessThan(app.buttons["playFreedoom1"].frame.maxY,
                          app.navigationBars.firstMatch.frame.maxY + 1,
                          "the shelf did not scroll its first row out from under the bar")
        assertActionsPoint(at: lastLeft, in: app, "last row, left, scrolled")
        assertActionsPoint(at: lastRight, in: app, "last row, right, scrolled")
    }

    /// Taps `tile`, checks that the popover's arrow touches it, and takes
    /// the actions down again.
    @MainActor
    private func assertActionsPoint(at tile: XCUIElement, in app: XCUIApplication, _ what: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "\(what): no tile", file: file, line: line)
        let tileFrame = tile.frame
        tile.tap()
        let continueAction = app.buttons["continueAction"].firstMatch
        XCTAssertTrue(continueAction.waitForExistence(timeout: 5), "\(what): the actions never came up",
                      file: file, line: line)
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5),
                      "\(what): the actions are not a popover; this test measures a popover's arrow",
                      file: file, line: line)
        // The popover's frame includes its arrow; the dialog's sheet inside
        // it does not. The side on which the popover reaches past the sheet
        // is the side the arrow is on, and that edge is the arrow's tip.
        let outer = popover.frame
        let inner = popover.sheets.firstMatch.frame
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "actions for \(what)"
        shot.lifetime = .keepAlways
        add(shot)

        let tip: CGRect
        if outer.maxY - inner.maxY > 4 {
            tip = CGRect(x: outer.minX, y: outer.maxY, width: outer.width, height: 0)
        } else if inner.minY - outer.minY > 4 {
            tip = CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: 0)
        } else if outer.maxX - inner.maxX > 4 {
            tip = CGRect(x: outer.maxX, y: outer.minY, width: 0, height: outer.height)
        } else if inner.minX - outer.minX > 4 {
            tip = CGRect(x: outer.minX, y: outer.minY, width: 0, height: outer.height)
        } else {
            XCTFail("\(what): no arrow found; popover \(outer), sheet \(inner)", file: file, line: line)
            dismissActions(in: app, continueAction)
            return
        }
        // The arrow's tip sits on the anchor's edge; a few points of slack
        // for the gap UIKit leaves between the two.
        XCTAssertTrue(tileFrame.insetBy(dx: -8, dy: -8).intersects(tip),
                      "\(what): the actions' arrow (\(tip)) does not touch the tapped tile \(tileFrame); popover \(outer)",
                      file: file, line: line)
        // And the popover does not sit on the tile it points at.
        XCTAssertFalse(inner.insetBy(dx: 1, dy: 1).intersects(tileFrame),
                       "\(what): the actions cover the tapped tile \(tileFrame); sheet \(inner)",
                       file: file, line: line)
        dismissActions(in: app, continueAction)
    }

    @MainActor
    private func dismissActions(in app: XCUIApplication, _ continueAction: XCUIElement) {
        let region = app.otherElements["PopoverDismissRegion"]
        if region.exists { region.tap() }
        XCTAssertTrue(continueAction.waitForNonExistence(timeout: 5), "the actions did not go away")
    }
}
