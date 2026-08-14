import XCTest

extension XCTestCase {
    /// Taps a text field, clears any existing contents, and types `text`.
    /// Shared by the preset-creation / edit / RealWAD UI flows.
    func clearAndType(_ field: XCUIElement, _ text: String) {
        field.tap()
        if let existing = field.value as? String, !existing.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(text)
    }

    /// Opens the Manage door from the shelf.
    ///
    /// The shelf replaced the Play/Library `TabView` (spec §§2–3), so tests
    /// that used to reach the library with `app.tabBars.buttons["Library"]`
    /// push Manage instead. Only the route moved: what those tests assert once
    /// they arrive is unchanged.
    func openManage(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let manage = app.buttons["manageButton"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10),
                      "Manage door missing from the shelf", file: file, line: line)
        manage.tap()
    }

    /// Pops Manage back to the shelf. The back button is titled with the
    /// shelf's own navigation title.
    func returnToShelf(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons["WADdle"]
        if back.waitForExistence(timeout: 5) { back.tap() }
    }
}
