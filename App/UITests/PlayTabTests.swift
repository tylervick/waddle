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
        app.provideFreedoom()
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
        app.provideFreedoom()
        // Reset so the base game starts with no override (the "Default" state).
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launch()

        // Open the game page and set the Controls override to MODERN. Modern is
        // distinct from the global default (Classic), so a persisted Modern is
        // unambiguous — the no-override label renders as "Default (Classic)",
        // which must NOT be mistaken for a saved selection. `schemePicker` sits
        // in the page's settings section, below the header/base/files sections,
        // so it needs scrolling into view first (lazy Form — see
        // docs/learnings/lazy-form-hides-rows-from-uitests.md).
        openGamePage(app, tile: "playFreedoom1")
        let picker = app.buttons["schemePicker"]
        scrollTo(picker, in: app)
        picker.tap()
        app.buttons["Modern"].tap()

        // Pop back to the shelf (the game page is pushed, not a sheet, so this
        // replaces the old drag-to-dismiss gesture) and confirm it's gone.
        returnToShelf(app)
        XCTAssertFalse(app.buttons["schemePicker"].exists, "game page did not pop as expected")

        // Reopen the page — the override must have persisted as Modern.
        openGamePage(app, tile: "playFreedoom1")
        let reopened = app.buttons["schemePicker"]
        scrollTo(reopened, in: app)
        XCTAssertTrue(reopened.label.contains("Modern"),
                      "scheme override did not persist across reopen; picker label = '\(reopened.label)'")
    }

    /// Add is a menu of two doors (#500): From Files… and From a Link….
    /// The link sheet refuses a plain `http` link in place, with the reason,
    /// and fetches nothing; Cancel closes it. No step here touches the
    /// network.
    @MainActor
    func testAddFromALinkRefusesAPlainHTTPLink() {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launch()
        let add = app.buttons["importButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Add missing from the shelf")
        add.tap()
        XCTAssertTrue(app.buttons["importFromFiles"].waitForExistence(timeout: 5), "Add's menu has no From Files…")
        let fromLink = app.buttons["importFromLink"]
        XCTAssertTrue(fromLink.waitForExistence(timeout: 5), "Add's menu has no From a Link…")
        fromLink.tap()

        let field = app.textFields["linkImportField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the link sheet never opened")
        field.tap()
        field.typeText("http://example.com/map.wad")
        app.buttons["linkImportDownload"].tap()

        let error = app.staticTexts["linkImportError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5), "a plain http link was not refused")
        XCTAssertTrue(error.label.contains("https://"), "the refusal does not say what to do; label = '\(error.label)'")
        XCTAssertFalse(app.buttons["linkImportCancel"].exists, "a refused link started a download")

        app.navigationBars["Add From a Link"].buttons["Cancel"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Cancel did not close the link sheet")
    }
}
