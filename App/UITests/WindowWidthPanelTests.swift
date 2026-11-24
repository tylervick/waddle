import XCTest

/// The panel when the window itself changes width class (issue #520): an
/// iPad's window narrowed to compact width, with no fold anywhere.
///
/// SwiftUI takes the inspector's column down as the window narrows and, on
/// an iPad, does not put the panel up again in its compact form. What the
/// page had presented goes with it, and its dismissal used to cancel what it
/// guarded: a save warning was gone, its change never made, and the panel
/// with it. `ShelfPanelModel.panelTakenDown` is the fix.
///
/// Only an iPad with windowed apps can do this: the test narrows the window
/// by dragging SpringBoard's resize grabber, and skips where there is none
/// (every phone, so the iPhone run in CI skips it). An extension of
/// `PlayTabTests` so it sits beside the fold's version of the same check.
extension PlayTabTests {

    @MainActor
    func testNarrowingTheWindowKeepsTheSaveWarningUpAndItsAnswerStillApplies() throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var grabber: XCUIElement?
        let app = launchWithASavedCopy { first in
            grabber = Self.resizeGrabber(in: springboard)
            if let grabber { self.restoreFullWidth(first, grabber: grabber, springboard: springboard) }
        }
        guard let grabber else {
            throw XCTSkip("this device has no window to resize (no SpringBoard resize grabber)")
        }
        // Whatever happens below, the next test gets a whole window back:
        // the size a window is left at is the size it launches at.
        addTeardownBlock { @MainActor in
            let app = XCUIApplication()
            app.provideFreedoom()
            if app.state != .runningForeground { app.launch() }
            self.restoreFullWidth(app, grabber: grabber, springboard: springboard)
        }

        // Regular width: the page opens as the column beside the shelf.
        let tile = app.buttons["game-\(Self.savedCopyName)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "the copy's tile is missing")
        tile.press(forDuration: 1.0)
        app.buttons["Details"].tap()
        XCTAssertTrue(app.buttons["panelDoneButton"].waitForExistence(timeout: 10),
                      "the copy's page did not open as the panel")
        let picker = app.buttons["basePicker"]
        let changeAnyway = raiseTheSaveWarning(in: app, picker: picker)

        // Narrow the window to a phone's width.
        let full = app.windows.firstMatch.frame.width
        drag(grabber, toWidth: 375, of: app)
        XCTAssertTrue(waitUntilTrue { app.windows.firstMatch.frame.width < full * 0.6 },
                      "the window did not narrow: \(app.windows.firstMatch.frame)")
        XCTAssertTrue(waitForPanelSwap(in: app), "the swap of panel trees never settled")
        XCTAssertTrue(waitUntilTrue(timeout: 12) { changeAnyway.exists && changeAnyway.isHittable },
                      "narrowed, the save warning was dropped")

        changeAnyway.tap()
        assertStoredBase(of: Self.savedCopyName, is: "Freedoom Phase 2", after: changeAnyway, in: app)
    }

    /// A large iPhone turned from landscape, where its window is regular
    /// width and the panel is a column, to portrait, where it is compact:
    /// the open panel stays, as the inspector's sheet, and turned back it is
    /// the column again. This is not new. With `panelTakenDown` switched
    /// off it passes too on an iPhone 18 Pro Max (2026-11-24), so SwiftUI
    /// carries the panel across a rotation by itself, as it does on an
    /// iPhone Duo folded shut, and only an iPad window narrowed by its
    /// grabber loses it. It is here so the narrowing fix, which also hears
    /// about this change of width class, is seen not to disturb it.
    /// Skips where landscape is compact too (an iPhone 18 Pro: Details then
    /// pushes the page) and on an iPad.
    @MainActor
    func testTurningAnOpenPanelToPortraitKeepsItAsASheet() throws {
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.provideFreedoom()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["importButton"].waitForExistence(timeout: 30), "the shelf never appeared")
        guard XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .descendants(matching: .any).matching(identifier: "resize-grabber").firstMatch.exists == false else {
            throw XCTSkip("an iPad: its window is regular in both orientations")
        }
        openGamePage(app, tile: "playFreedoom1")
        let done = app.buttons["panelDoneButton"]
        guard done.waitForExistence(timeout: 3) else {
            throw XCTSkip("landscape is compact on this device: the page was pushed, there is no panel")
        }

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForPanelSwap(in: app), "the swap of panel trees never settled")
        XCTAssertTrue(waitUntilTrue(timeout: 8) { done.exists && done.isHittable },
                      "turned to portrait, the open panel was lost")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForPanelSwap(in: app), "the swap of panel trees never settled")
        XCTAssertTrue(waitUntilTrue(timeout: 8) { done.exists && done.isHittable && app.buttons["importButton"].isHittable },
                      "turned back to landscape, the panel is not the column beside the shelf")
    }

    // MARK: helpers

    /// SpringBoard's resize grabber for this app's window, or nil where
    /// windows cannot be resized.
    @MainActor
    private static func resizeGrabber(in springboard: XCUIApplication) -> XCUIElement? {
        let grabber = springboard.descendants(matching: .any).matching(identifier: "resize-grabber").firstMatch
        return grabber.waitForExistence(timeout: 3) ? grabber : nil
    }

    /// Drags the grabber (the window's bottom-right corner) so that the
    /// window is about `width` points wide.
    @MainActor
    private func drag(_ grabber: XCUIElement, toWidth width: CGFloat, of app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        let start = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: width - window.width, dy: 0))
        start.press(forDuration: 0.6, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
    }

    /// The window back to the whole screen: dragged out to the screen's
    /// right edge, then, if the system kept its left edge in place, moved
    /// to the left edge and dragged out again.
    @MainActor
    private func restoreFullWidth(_ app: XCUIApplication, grabber: XCUIElement, springboard: XCUIApplication) {
        let screen = springboard.windows.firstMatch.frame
        for _ in 0..<3 {
            let window = app.windows.firstMatch.frame
            if window.minX <= 0.5, window.width >= screen.width - 0.5 { return }
            print("restoreFullWidth: window \(window) on \(screen)")
            if window.minX > 0.5 {
                // Moved by its top edge, above the app's own bar.
                let grip = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                    .withOffset(CGVector(dx: 0, dy: 8))
                grip.press(forDuration: 0.6, thenDragTo: grip.withOffset(CGVector(dx: -window.minX, dy: 0)),
                           withVelocity: .slow, thenHoldForDuration: 0.3)
                _ = waitUntilTrue(timeout: 3) { app.windows.firstMatch.frame.minX <= 0.5 }
            }
            drag(grabber, toWidth: screen.width + 40, of: app)
            _ = waitUntilTrue(timeout: 3) {
                let now = app.windows.firstMatch.frame
                return now.minX <= 0.5 && now.width >= screen.width - 0.5
            }
        }
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.minX <= 0.5 && window.width >= screen.width - 0.5,
                      "could not give the window the whole screen back: \(window) on \(screen)")
    }

    private func waitUntilTrue(timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }
}
