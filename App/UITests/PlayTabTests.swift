import XCTest

final class PlayTabTests: XCTestCase {
    @MainActor
    func testBaseGameDetailControlsOverridePersists() {
        let app = XCUIApplication()
        app.launch()
        let tile = app.buttons["playFreedoom1"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.press(forDuration: 1.0)               // context menu
        app.buttons["Details"].tap()
        let picker = app.buttons["detailSchemePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["Classic"].tap()
        // reopen and confirm the selection stuck
        XCTAssertTrue(app.buttons["detailSchemePicker"].waitForExistence(timeout: 5))
    }
}
