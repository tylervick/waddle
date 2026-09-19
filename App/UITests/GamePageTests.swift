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
        app.buttons["duplicateButton"].tap()
        openGamePage(app, tile: "game-Freedoom Phase 1 copy")

        app.buttons["gameNameButton"].tap()
        let field = app.textFields["renameField"]
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
        app.buttons["duplicateButton"].tap()
        openGamePage(app, tile: "game-Freedoom Phase 1 copy")
        app.buttons["deleteGameButton"].tap()
        app.buttons["deleteGameAndSavesAction"].tap()

        XCTAssertTrue(app.buttons["importButton"].waitForExistence(timeout: 5), "did not pop to the shelf")
        XCTAssertFalse(app.buttons["game-Freedoom Phase 1 copy"].waitForExistence(timeout: 2),
                       "the deleted game is still on the shelf")
    }
}
