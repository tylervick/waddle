import XCTest

/// A tile's Continue / New Game / Details actions point at that tile.
///
/// On iOS 26 and later a confirmation dialog on an iPhone is a popover with
/// an arrow, anchored to the view the modifier is attached to. The shelf
/// attached its one dialog to the whole screen, so every tile's actions came
/// up in the same place at the top of the shelf, their arrow pointing at the
/// screen's middle and at no tile (TestFlight feedback on build 323, issue
/// 532). This measures the live popover against the tapped tile's frame: the
/// arrow's tip has to land on the tile, on its edge and within its span, for
/// a tile in each column, in the first row and, after the shelf has scrolled,
/// in the last. And the actions stay up and on their tile when the phone is
/// turned, which a dialog hosted on the tile itself did not (review of pull
/// request 536): the lazy grid rebuilt the tile and took the dialog with it.
/// A tile's Delete confirmation, from its long-press menu, is held to the
/// same (issue #535).
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

    /// Taps `tile`, checks that the popover's arrow lands on it, and takes
    /// the actions down again.
    @MainActor
    private func assertActionsPoint(at tile: XCUIElement, in app: XCUIApplication, _ what: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "\(what): no tile", file: file, line: line)
        tile.tap()
        let continueAction = app.buttons["continueAction"].firstMatch
        XCTAssertTrue(continueAction.waitForExistence(timeout: 5), "\(what): the actions never came up",
                      file: file, line: line)
        assertArrowPoints(at: tile, in: app, what, file: file, line: line)
        dismissActions(in: app, continueAction)
    }

    /// Asserts that the actions' popover is up and its arrow lands on
    /// `target`, allowing `timeout` for a popover still moving after a
    /// rotation or a change of pose to settle. Attaches a screenshot.
    @MainActor
    func assertArrowPoints(at target: XCUIElement, in app: XCUIApplication, _ what: String,
                           timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line) {
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5),
                      "\(what): the actions are not up as a popover; this test measures a popover's arrow",
                      file: file, line: line)
        var miss: String? = "never measured"
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            miss = arrowMiss(popover: popover, target: target, in: app)
            if miss == nil { break }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "actions for \(what)"
        shot.lifetime = .keepAlways
        add(shot)
        if let miss { XCTFail("\(what): \(miss)", file: file, line: line) }
    }

    /// Why the popover's arrow does not land on `target`, or nil when it does.
    ///
    /// The popover's frame includes its arrow; the dialog's sheet inside it
    /// does not. The side on which the popover reaches past the sheet is the
    /// arrow's side, and that edge is where its tip is. Along that edge the
    /// arrow is not in the tree, so where it is follows from how UIKit
    /// places a popover: centred on its anchor unless that would cross the
    /// window's margin, in which case it is pushed in and the arrow slides
    /// toward the anchor. So an unpushed popover's arrow is at its middle;
    /// one pushed in from the leading margin has its arrow between its own
    /// leading edge and its middle; one pushed in from the trailing margin,
    /// between its middle and its trailing edge. Two neighbouring tiles of
    /// one row give ranges that do not meet, which is what a check on the
    /// tip's edge alone could not tell apart.
    @MainActor
    private func arrowMiss(popover: XCUIElement, target: XCUIElement, in app: XCUIApplication) -> String? {
        guard popover.exists, target.exists else {
            return "the popover (\(popover.exists)) or its tile (\(target.exists)) is gone"
        }
        let outer = popover.frame, inner = popover.sheets.firstMatch.frame
        let window = app.windows.firstMatch.frame, tile = target.frame
        let slack: CGFloat = 8, margin: CGFloat = 14
        func along(_ lo: CGFloat, _ hi: CGFloat, _ windowLo: CGFloat, _ windowHi: CGFloat) -> ClosedRange<CGFloat> {
            let mid = (lo + hi) / 2
            let pushedLo = lo - windowLo < margin, pushedHi = windowHi - hi < margin
            switch (pushedLo, pushedHi) {
            case (false, false): return (mid - 3)...(mid + 3)
            case (true, false): return lo...(mid + 3)
            case (false, true): return (mid - 3)...hi
            case (true, true): return lo...hi
            }
        }
        let tipEdge: CGFloat, tipSpan: ClosedRange<CGFloat>, onEdge: Bool, inSpan: Bool
        if outer.maxY - inner.maxY > 4 || inner.minY - outer.minY > 4 {
            tipEdge = outer.maxY - inner.maxY > 4 ? outer.maxY : outer.minY
            tipSpan = along(outer.minX, outer.maxX, window.minX, window.maxX)
            onEdge = (tile.minY - slack)...(tile.maxY + slack) ~= tipEdge
            inSpan = tipSpan.overlaps(tile.minX...tile.maxX)
        } else if outer.maxX - inner.maxX > 4 || inner.minX - outer.minX > 4 {
            tipEdge = outer.maxX - inner.maxX > 4 ? outer.maxX : outer.minX
            tipSpan = along(outer.minY, outer.maxY, window.minY, window.maxY)
            onEdge = (tile.minX - slack)...(tile.maxX + slack) ~= tipEdge
            inSpan = tipSpan.overlaps(tile.minY...tile.maxY)
        } else {
            return "no arrow found; popover \(outer), sheet \(inner)"
        }
        guard onEdge, inSpan else {
            return "the arrow (edge \(tipEdge), along \(tipSpan)) does not land on the tile \(tile); popover \(outer), sheet \(inner)"
        }
        // At the sizes these tests run, the actions sit beside a tile.
        if inner.insetBy(dx: 1, dy: 1).intersects(tile) {
            return "the actions cover their tile \(tile); sheet \(inner)"
        }
        return nil
    }

    @MainActor
    private func dismissActions(in app: XCUIApplication, _ action: XCUIElement) {
        let region = app.otherElements["PopoverDismissRegion"]
        if region.exists { region.tap() }
        XCTAssertTrue(action.waitForNonExistence(timeout: 5), "the actions did not go away")
    }

    /// Turned from portrait to landscape and back with a tile's actions up,
    /// the actions stay up and stay on their tile. A dialog hosted on the
    /// tile went with it when the lazy grid rebuilt the tile for its new
    /// columns, on the way back to portrait (review of pull request 536).
    /// The tile is low in a scrolled shelf, so landscape's shorter window
    /// puts it out of view unless the shelf brings it back.
    @MainActor
    func testATilesActionsStayOnItThroughATurnToLandscapeAndBack() throws {
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait
        let app = launchFilledShelf()
        app.swipeUp()
        let tile = try XCTUnwrap(edgeRow(in: app, bottom: true)?.last, "no row of tiles on screen")
        let id = tile.identifier
        tile.tap()
        let continueAction = app.buttons["continueAction"].firstMatch
        XCTAssertTrue(continueAction.waitForExistence(timeout: 5), "\(id): the actions never came up")
        assertArrowPoints(at: app.buttons[id], in: app, "\(id), portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        try requireTurn(to: .landscape, in: app)
        assertArrowPoints(at: app.buttons[id], in: app, "\(id), turned to landscape", timeout: 8)

        XCUIDevice.shared.orientation = .portrait
        try requireTurn(to: .portrait, in: app)
        assertArrowPoints(at: app.buttons[id], in: app, "\(id), turned back to portrait", timeout: 8)
        XCTAssertTrue(continueAction.exists, "\(id): the actions did not survive the turns")
    }

    /// Turned from landscape to portrait with a tile's actions up, they stay
    /// up and on their tile; the dialog on the tile was dropped at once for
    /// "Shelf 4", in the second row (review of pull request 536).
    @MainActor
    func testATilesActionsStayOnItThroughATurnToPortrait() throws {
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait
        let app = launchFilledShelf()
        XCUIDevice.shared.orientation = .landscapeLeft
        try requireTurn(to: .landscape, in: app)
        // Below the first row, as in the review: a first-row tile kept its
        // dialog through the turn even when the tile hosted it.
        let id = "game-Shelf 4"
        let tile = app.buttons[id]
        scrollTo(tile, in: app)
        tile.tap()
        let continueAction = app.buttons["continueAction"].firstMatch
        XCTAssertTrue(continueAction.waitForExistence(timeout: 5), "\(id): the actions never came up")
        assertArrowPoints(at: app.buttons[id], in: app, "\(id), landscape")

        XCUIDevice.shared.orientation = .portrait
        try requireTurn(to: .portrait, in: app)
        assertArrowPoints(at: app.buttons[id], in: app, "\(id), turned to portrait", timeout: 8)
        XCTAssertTrue(continueAction.exists, "\(id): the actions did not survive the turn")
    }

    /// A tile's Delete confirmation, reached from its long-press menu,
    /// points at that tile too. It hung off the shelf's root, as the actions
    /// once did, and came up over the hero at the top of the screen from
    /// every tile (issue #535). Only a copy has Delete (a base game is
    /// hidden instead), so this measures rows of copies alone: a row at
    /// rest, and after scrolling the last row and the one above it.
    @MainActor
    func testATilesDeletePointsAtThatTile() throws {
        let app = launchFilledShelf()

        let upper = try XCTUnwrap(copyRows(in: app).first, "no row of copies on screen")
        XCTAssertGreaterThan(upper.count, 1, "one column only: \(upper)")
        assertDeletePoints(at: upper[0], in: app, "upper row, first column")
        assertDeletePoints(at: upper[upper.count - 1], in: app, "upper row, last column")

        var lowest = ""
        for _ in 0..<30 {
            app.swipeUp()
            let now = visibleRows(in: app).last?.last?.identifier ?? ""
            if now == lowest { break }
            lowest = now
        }
        XCTAssertFalse(app.buttons["playFreedoom1"].isHittable,
                       "the shelf did not scroll its first row away")
        let rows = copyRows(in: app)
        let bottom = try XCTUnwrap(rows.last, "no row of copies on screen after scrolling")
        assertDeletePoints(at: bottom[0], in: app, "last row, first column, scrolled")
        if bottom.count > 1 {
            assertDeletePoints(at: bottom[bottom.count - 1], in: app, "last row, last column, scrolled")
        }
        // A last row of one leaves the other column to the row above it.
        XCTAssertGreaterThan(rows.count, 1, "no row of copies above the last")
        guard rows.count > 1 else { return }
        let above = rows[rows.count - 2]
        assertDeletePoints(at: above[above.count - 1], in: app, "second-last row, last column, scrolled")
    }

    /// Turned from portrait to landscape and back with a tile's Delete
    /// confirmation up, it stays up and on its tile, as the actions do.
    @MainActor
    func testATilesDeleteStaysOnItThroughATurnToLandscapeAndBack() throws {
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait
        let app = launchFilledShelf()
        app.swipeUp()
        let tile = try XCTUnwrap(copyRows(in: app).last?.last, "no row of copies on screen")
        let id = tile.identifier
        let deleteAction = openDelete(on: tile, in: app, id)
        assertArrowPoints(at: app.buttons[id], in: app, "\(id)'s Delete, portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        try requireTurn(to: .landscape, in: app)
        assertArrowPoints(at: app.buttons[id], in: app, "\(id)'s Delete, turned to landscape", timeout: 8)

        XCUIDevice.shared.orientation = .portrait
        try requireTurn(to: .portrait, in: app)
        assertArrowPoints(at: app.buttons[id], in: app, "\(id)'s Delete, turned back to portrait", timeout: 8)
        XCTAssertTrue(deleteAction.exists, "\(id): the Delete confirmation did not survive the turns")
    }

    /// Turned from landscape to portrait with a second-row tile's Delete
    /// confirmation up, it stays up and on its tile.
    @MainActor
    func testATilesDeleteStaysOnItThroughATurnToPortrait() throws {
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait
        let app = launchFilledShelf()
        XCUIDevice.shared.orientation = .landscapeLeft
        try requireTurn(to: .landscape, in: app)
        let id = "game-Shelf 4"
        let tile = app.buttons[id]
        scrollTo(tile, in: app)
        let deleteAction = openDelete(on: tile, in: app, id)
        assertArrowPoints(at: app.buttons[id], in: app, "\(id)'s Delete, landscape")

        XCUIDevice.shared.orientation = .portrait
        try requireTurn(to: .portrait, in: app)
        assertArrowPoints(at: app.buttons[id], in: app, "\(id)'s Delete, turned to portrait", timeout: 8)
        XCTAssertTrue(deleteAction.exists, "\(id): the Delete confirmation did not survive the turn")
    }

    /// Visible rows made only of copies ("Shelf n"), the games that have
    /// Delete, so a row's first and last tile are its first and last column.
    @MainActor
    private func copyRows(in app: XCUIApplication) -> [[XCUIElement]] {
        visibleRows(in: app).filter { row in row.allSatisfy { $0.identifier.hasPrefix("game-Shelf ") } }
    }

    /// Opens `target`'s Delete confirmation from its long-press menu, and
    /// returns the confirmation's Delete Game and Saves.
    @MainActor
    func openDelete(on target: XCUIElement, in app: XCUIApplication, _ what: String,
                    file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(target.waitForExistence(timeout: 5), "\(what): not on screen", file: file, line: line)
        target.press(forDuration: 1.0)
        let menuDelete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(menuDelete.waitForExistence(timeout: 5), "\(what): the long-press menu has no Delete",
                      file: file, line: line)
        menuDelete.tap()
        let deleteAction = app.buttons.matching(identifier: "deleteGameAndSavesAction").firstMatch
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5), "\(what): the Delete confirmation never came up",
                      file: file, line: line)
        return deleteAction
    }

    /// Opens `tile`'s Delete confirmation, checks that the popover's arrow
    /// lands on it, and cancels it.
    @MainActor
    private func assertDeletePoints(at tile: XCUIElement, in app: XCUIApplication, _ what: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let deleteAction = openDelete(on: tile, in: app, what, file: file, line: line)
        assertArrowPoints(at: tile, in: app, "Delete, \(what)", file: file, line: line)
        dismissActions(in: app, deleteAction)
    }

    @MainActor
    private func launchFilledShelf() -> XCUIApplication {
        let app = XCUIApplication()
        app.provideFreedoom()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launchEnvironment["WADDLE_TEST_FILL_SHELF"] = "40"
        app.launch()
        XCTAssertTrue(app.buttons["importButton"].waitForExistence(timeout: 30), "the shelf never appeared")
        XCTAssertTrue(app.buttons["playFreedoom1"].waitForExistence(timeout: 10), "no first tile")
        return app
    }

    private enum Turn { case portrait, landscape }

    /// Waits for the window to take the shape asked for. A simulator that
    /// never turns its interface (`docs/learnings/simulator-test-hazards.md`)
    /// is skipped rather than failed: it can say nothing about a turn.
    @MainActor
    private func requireTurn(to turn: Turn, in app: XCUIApplication) throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let window = app.windows.firstMatch.frame
            if (turn == .landscape) == (window.width > window.height) {
                Thread.sleep(forTimeInterval: 1)
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw XCTSkip("the interface never turned to \(turn); this simulator cannot test a turn")
    }
}
