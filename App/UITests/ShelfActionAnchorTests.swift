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
/// column, in the first row and, after the shelf has scrolled, in the last.
///
/// An extension of `PlayTabTests`, in its own file, so it runs in the set a
/// pull request runs (`.github/workflows/ui-tests.yml`).
extension PlayTabTests {

    @MainActor
    func testATilesActionsPointAtThatTile() throws {
        let app = XCUIApplication()
        app.provideFreedoom()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        // Forty copies of Freedoom Phase 1 and a save for every game: a
        // shelf that scrolls on an iPhone and on the 13-inch iPad the UI
        // suite also runs on, every tile tapping to its actions.
        app.launchEnvironment["WADDLE_TEST_FILL_SHELF"] = "40"
        app.launch()
        XCTAssertTrue(app.buttons["importButton"].waitForExistence(timeout: 30), "the shelf never appeared")
        XCTAssertTrue(app.buttons["playFreedoom1"].waitForExistence(timeout: 10), "no first tile")

        // The first row, its first and last column, with the shelf at rest.
        let top = try XCTUnwrap(edgeRow(in: app, bottom: false), "no row of tiles on screen")
        XCTAssertGreaterThan(top.last.frame.minX, top.first.frame.maxX, "one column only: \(top)")
        assertActionsPoint(at: top.first, in: app, "first row, first column")
        assertActionsPoint(at: top.last, in: app, "first row, last column")

        // The last row, after scrolling to it: the defect put the popover in
        // the same place wherever the shelf had scrolled to.
        var lowest = ""
        for _ in 0..<30 {
            app.swipeUp()
            let now = visibleRows(in: app).last?.last?.identifier ?? ""
            if now == lowest { break }
            lowest = now
        }
        XCTAssertFalse(app.buttons["playFreedoom1"].isHittable,
                       "the shelf did not scroll its first row away")
        let bottom = try XCTUnwrap(edgeRow(in: app, bottom: true), "no row of tiles on screen after scrolling")
        assertActionsPoint(at: bottom.first, in: app, "last row, first column, scrolled")
        if bottom.last.identifier != bottom.first.identifier {
            assertActionsPoint(at: bottom.last, in: app, "last row, last column, scrolled")
        }
        // A last row of one leaves the other column to the row above it.
        let above = try XCTUnwrap(rowAbove(bottom.first, in: app), "no row above the last")
        assertActionsPoint(at: above.last, in: app, "second-last row, last column, scrolled")
    }

    /// The fully visible game tiles, as rows top to bottom.
    @MainActor
    private func visibleRows(in app: XCUIApplication) -> [[XCUIElement]] {
        let window = app.windows.firstMatch.frame
        let barBottom = app.navigationBars.firstMatch.frame.maxY
        let tiles = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'game-' OR identifier == 'playFreedoom1'"))
            .allElementsBoundByIndex
            .filter { $0.exists && window.contains($0.frame) && $0.frame.minY >= barBottom - 1 && $0.isHittable }
        var rows: [[XCUIElement]] = []
        for tile in tiles.sorted(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }) {
            if let last = rows.last?.first, abs(last.frame.minY - tile.frame.minY) < 2 {
                rows[rows.count - 1].append(tile)
            } else {
                rows.append([tile])
            }
        }
        return rows
    }

    @MainActor
    private func edgeRow(in app: XCUIApplication, bottom: Bool) -> (first: XCUIElement, last: XCUIElement)? {
        let rows = visibleRows(in: app)
        guard let row = bottom ? rows.last : rows.first, let first = row.first, let last = row.last
        else { return nil }
        return (first, last)
    }

    @MainActor
    private func rowAbove(_ tile: XCUIElement, in app: XCUIApplication) -> (first: XCUIElement, last: XCUIElement)? {
        let rows = visibleRows(in: app)
        guard let index = rows.firstIndex(where: { $0.contains { $0.identifier == tile.identifier } }),
              index > 0, let first = rows[index - 1].first, let last = rows[index - 1].last
        else { return nil }
        return (first, last)
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
