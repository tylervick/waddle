import XCTest

/// The game page (spec §3.2) end to end on the bundled Freedoom Phase 1, so no
/// provisioned fixtures are needed.
final class GamePageTests: XCTestCase {
    @MainActor
    func testDuplicateFromABaseGameAddsATile() {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launch()

        openGamePage(app, tile: "playFreedoom1")
        scrollTo(app.buttons["duplicateButton"], in: app)
        app.buttons["duplicateButton"].tap()

        // Duplicate pops back to the shelf, where the copy is a fresh tile.
        XCTAssertTrue(app.buttons["game-Freedoom Phase 1 copy"].waitForExistence(timeout: 5),
                      "the copy never appeared on the shelf")
        XCTAssertTrue(app.buttons["playFreedoom1"].exists, "the original is untouched")
    }

    @MainActor
    func testRenameFromThePageUpdatesTheTile() {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launch()

        openGamePage(app, tile: "playFreedoom1")
        scrollTo(app.buttons["duplicateButton"], in: app)
        app.buttons["duplicateButton"].tap()
        openGamePage(app, tile: "game-Freedoom Phase 1 copy")

        app.buttons["gameNameButton"].tap()
        let field = renameField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "rename field never appeared")
        clearAndType(field, "Renamed Game")
        app.buttons["Save"].tap()
        returnToShelf(app)

        XCTAssertTrue(app.buttons["game-Renamed Game"].waitForExistence(timeout: 5),
                      "the tile did not pick up the new name")
    }

    @MainActor
    func testDeleteFromThePageRemovesTheTile() {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launch()

        openGamePage(app, tile: "playFreedoom1")
        scrollTo(app.buttons["duplicateButton"], in: app)
        app.buttons["duplicateButton"].tap()
        openGamePage(app, tile: "game-Freedoom Phase 1 copy")
        scrollTo(app.buttons["deleteGameButton"], in: app)
        app.buttons["deleteGameButton"].tap()
        // Confirmation-dialog buttons surface twice in the accessibility tree
        // (docs/learnings/alert-textfield-identifiers-are-dropped.md) — `.firstMatch`
        // avoids the "multiple matching elements" ambiguity error.
        app.buttons.matching(identifier: "deleteGameAndSavesAction").firstMatch.tap()

        XCTAssertTrue(app.buttons["importButton"].waitForExistence(timeout: 5), "did not pop to the shelf")
        XCTAssertFalse(app.buttons["game-Freedoom Phase 1 copy"].waitForExistence(timeout: 2),
                       "the deleted game is still on the shelf")
    }

    /// A page wider than it is tall puts its art beside the title and the
    /// buttons (design-system spec §8). Whether it may is decided from a
    /// measurement of the caption's widest word, taken from a hidden copy of
    /// it (issue #425), so a measurement that never arrived, or came out too
    /// wide, would stack every landscape page and nothing else would say so:
    /// the first version of that rule did exactly that to a closed iPhone
    /// Duo at the largest text size (review of pull request 435).
    @MainActor
    func testTheHeroIsSideBySideOnALandscapePhone() {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        expectation(for: landscape, evaluatedWith: nil)
        waitForExpectations(timeout: 15)

        openGamePage(app, tile: "playFreedoom1")
        let title = app.buttons["gameNameButton"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the page's title is missing")
        // Stacked, the title starts at the page's leading edge, under the
        // art. Beside the art it starts past the art, which is up to half
        // the row and never less than its 96 pt floor's width.
        let beside = NSPredicate { _, _ in title.frame.minX > app.frame.width * 0.25 }
        expectation(for: beside, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        let play = app.buttons["playButton"]
        XCTAssertGreaterThan(play.frame.minX, app.frame.width * 0.25,
                             "the Play button is not beside the art; frame \(play.frame)")
    }

    /// At an accessibility text size the page builds its menu rows by hand
    /// (issue #425: the system's row is sized for a one-line value). A
    /// hand-built row has to stay the control the system's is: the same
    /// label and value for VoiceOver, a touch anywhere on the row opening
    /// the menu, and a choice from it taking effect.
    @MainActor
    func testTheMenuRowsAtAnAccessibilitySizeBehaveLikeTheSystemPicker() {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launch()
        openGamePage(app, tile: "playFreedoom1")
        let system = app.buttons["schemePicker"]
        scrollTo(system, in: app)
        let systemLabel = system.label
        let systemValue = system.value as? String
        XCTAssertTrue(systemLabel.contains("Touch layout") && systemLabel.contains("Default"),
                      "the system picker no longer reads its title and choice as its label; label '\(systemLabel)', value '\(systemValue ?? "nil")'")
        app.terminate()

        app.launchArguments += ["-UIPreferredContentSizeCategoryName",
                                "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        openGamePage(app, tile: "playFreedoom1")
        let row = app.buttons["schemePicker"]
        scrollTo(row, in: app)
        XCTAssertEqual(row.label, systemLabel, "the hand-built row is labelled differently from the system picker")
        XCTAssertEqual(row.value as? String, systemValue, "the hand-built row's value differs from the system picker's")

        // The row spans its card, not just the words of the value: the
        // system's row opens from anywhere on it.
        XCTAssertGreaterThan(row.frame.width, app.frame.width * 0.6,
                             "only part of the row is the control; frame \(row.frame)")
        // The far end of the title's line, where the row has no text at all.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.2)).tap()
        let modern = app.buttons["Modern"]
        XCTAssertTrue(modern.waitForExistence(timeout: 5), "a touch on the row's empty end did not open the menu")
        modern.tap()
        XCTAssertTrue(app.buttons["schemePicker"].waitForExistence(timeout: 5))
        let chosen = app.buttons["schemePicker"]
        let predicate = NSPredicate(format: "value CONTAINS 'Modern' OR label CONTAINS 'Modern'")
        expectation(for: predicate, evaluatedWith: chosen)
        waitForExpectations(timeout: 5)
    }

    /// The title of a game with no space in its name is drawn with invisible
    /// breaks after its underscores, so that it wraps there and is not
    /// hyphenated inside a syllable at an accessibility text size (issue
    /// #441). None of that may reach what the title says: VoiceOver, and
    /// every test that finds the title, reads "Rename" and the plain name.
    ///
    /// Where the lines end cannot be asserted here; the accessibility tree
    /// has a text's string and frame and nothing about its lines.
    @MainActor
    func testAOneTokenTitleReadsItsPlainNameAtAnAccessibilityTextSize() {
        let name = "sunlust_final_v13"
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launch()
        openGamePage(app, tile: "playFreedoom1")
        scrollTo(app.buttons["duplicateButton"], in: app)
        app.buttons["duplicateButton"].tap()
        openGamePage(app, tile: "game-Freedoom Phase 1 copy")
        app.buttons["gameNameButton"].tap()
        let field = renameField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "rename field never appeared")
        clearAndType(field, name)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["gameNameButton"].waitForExistence(timeout: 5))
        app.terminate()

        // Same store, largest text size.
        app.launchEnvironment["WADDLE_RESET_STORE"] = nil
        app.launchArguments += ["-UIPreferredContentSizeCategoryName",
                                "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let tile = app.buttons["game-\(name)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "the renamed game is not on the shelf")
        scrollTo(tile, in: app, maxSwipes: 12)
        openGamePage(app, tile: "game-\(name)")

        let title = app.buttons["gameNameButton"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the page's title is missing")
        XCTAssertEqual(title.label, "Rename \(name)")
        XCTAssertFalse(title.label.unicodeScalars.contains("\u{200B}"), "the title reads an invisible character")
        // And nothing under it reads one either: the drawn text carries its
        // own label, the plain name.
        let drawn = title.staticTexts.allElementsBoundByIndex.map(\.label) + app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'sunlust'")).allElementsBoundByIndex.map(\.label)
        for label in drawn {
            XCTAssertFalse(label.unicodeScalars.contains("\u{200B}"), "a text on the page reads an invisible character: '\(label)'")
        }
    }
}
