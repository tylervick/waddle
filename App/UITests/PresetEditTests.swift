import XCTest

/// Regression coverage for the Task 5 review finding: the preset detail
/// page's Edit button used to set `editorLoadout` and call `dismiss()` on
/// the detail sheet in the same synchronous action -- the same
/// dismiss-then-present-in-one-transaction race Task 4 hit (and fixed in
/// cfaed69) on the create path, just untested on the Edit path. `PlayView`
/// now defers presenting the editor to the detail sheet's `onDismiss`, via a
/// `pendingEditLoadout` intent set instead of `editorLoadout` directly. This
/// exercises that path end-to-end: long-press a preset tile -> Details ->
/// Edit, and confirm the editor actually appears instead of silently no-op'ing.
final class PresetEditTests: XCTestCase {

    /// Clears any existing text in `field` (e.g. LoadoutEditorView's
    /// auto-generated name) before typing `text`.
    @MainActor
    func testEditFromDetailPageOpensEditor() {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launch()

        // Create a preset to edit.
        app.buttons["newLoadoutButton"].tap()

        let baseRow = app.buttons["createPresetBase-Freedoom Phase 1"]
        XCTAssertTrue(baseRow.waitForExistence(timeout: 5), "base-game picker row never appeared")
        baseRow.tap()

        let nameField = app.textFields["loadoutNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "seeded editor never appeared")
        clearAndType(nameField, "Edit Target")

        app.buttons["saveLoadoutButton"].tap()

        let tile = app.buttons["loadout-Edit Target"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "new preset tile never appeared on Play")

        // Open the detail page and tap Edit there -- this is the path under
        // test, distinct from the tile's own context-menu "Edit" shortcut.
        tile.press(forDuration: 1.0)               // context menu
        app.buttons["Details"].tap()

        let editButton = app.buttons["detailEditButton"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 5), "detail page's Edit button never appeared")
        editButton.tap()

        // Fails against the pre-fix bug: presenting the editor in the same
        // transaction as dismissing the detail sheet drops the editor
        // presentation entirely. Passes once the two are deferred across
        // separate transactions via onDismiss.
        XCTAssertTrue(app.textFields["loadoutNameField"].waitForExistence(timeout: 5),
                      "editor never appeared after tapping Edit on the detail page")
    }
}
