import XCTest

final class PlayTabTests: XCTestCase {
    /// Every art tile stays inside its grid cell. The 2026-08-21 design pass
    /// measured ~190 pt of tile in a 175 pt cell: the `scaledToFill` bitmap
    /// negotiated the tile's size past its column, every tile painted over
    /// the gap beside it, and no spacing constant could widen what was being
    /// painted over — the shelf read as having no padding at any gap value.
    /// Pure-geometry tests cannot see a rendered frame, so this measures the
    /// live accessibility hierarchy, the way `LiveDeviceOverlayLayoutTests`
    /// measures the overlay. Reintroduce image-driven sizing in
    /// `TitleArtView` and the gap and margin assertions here both fail.
    @MainActor
    func testTilesStayInsideTheirGridCells() {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launch()
        let one = app.buttons["playFreedoom1"]
        XCTAssertTrue(one.waitForExistence(timeout: 10))
        // Phase 2 has no stable identifier (only Phase 1 is load-bearing for
        // launch tests), so find it by its accessibility label.
        let two = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Freedoom Phase 2'")).firstMatch
        XCTAssertTrue(two.waitForExistence(timeout: 5))

        let lhs = one.frame, rhs = two.frame
        // Same row (portrait phones and every iPad width give at least two
        // columns, pinned by ShelfHeroLayoutTests), so these are neighbours.
        XCTAssertEqual(lhs.minY, rhs.minY, accuracy: 2, "tiles are not in one row")
        // The gap must survive rendering: 20 pt by Theme; anything under 12
        // means a tile is painting over it (the defect measured 5 pt).
        XCTAssertGreaterThanOrEqual(rhs.minX - lhs.maxX, 12,
                                    "inter-tile gap collapsed: \(lhs) vs \(rhs)")
        // The leading content margin must survive too: 16 pt by ShelfView;
        // the defect left 8.5. And the two cells must be the same width.
        XCTAssertGreaterThanOrEqual(lhs.minX, 12, "leading margin collapsed: \(lhs)")
        XCTAssertEqual(lhs.width, rhs.width, accuracy: 1)
    }

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
