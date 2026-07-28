import XCTest

/// Regression coverage for Plan B Task 4's create-path sheet-dismissal bug:
/// `LoadoutEditorView` is pushed into `PresetCreationFlow`'s own
/// `NavigationStack` via `.navigationDestination`, not presented as the
/// sheet's direct root, so its own `dismiss()` used to only pop back to the
/// base-game picker -- the enclosing sheet stayed open, `PlayView`'s
/// `.sheet(..., onDismiss: refresh)` never fired, and the new preset never
/// showed up on Play. Uses only the bundled Freedoom Phase 1 IWAD, so it
/// needs no provisioned fixture WADs (unlike RealWADTests).
final class PresetCreationTests: XCTestCase {

    /// Clears any existing text in `field` (e.g. LoadoutEditorView's
    /// auto-generated name) before typing `text`.
    @MainActor
    func testCreatingPresetClosesSheetAndShowsTileOnPlay() {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launch()

        app.buttons["newLoadoutButton"].tap()

        let baseRow = app.buttons["createPresetBase-Freedoom Phase 1"]
        XCTAssertTrue(baseRow.waitForExistence(timeout: 5), "base-game picker row never appeared")
        baseRow.tap()

        // The seeded editor opens auto-named "Freedoom Phase 1"; give it a
        // distinct name so the resulting tile's accessibility id
        // ("loadout-<name>") is unambiguous.
        let nameField = app.textFields["loadoutNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "seeded editor never appeared")
        clearAndType(nameField, "Smoke Preset")

        app.buttons["saveLoadoutButton"].tap()

        // Fails against the pre-fix bug: the sheet stays open on the
        // base-game picker, PlayView's onDismiss:refresh never fires, and
        // this tile never appears. Passes once Save/Cancel close the whole
        // sheet.
        XCTAssertTrue(app.buttons["loadout-Smoke Preset"].waitForExistence(timeout: 5),
                      "new preset tile never appeared on Play -- creation sheet likely did not close")
    }
}
