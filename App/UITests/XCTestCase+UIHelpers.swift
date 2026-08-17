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
    ///
    /// Asserts, unlike its first version. Every caller reaches this line
    /// directly after a successful `openManage`, so a missing back button means
    /// navigation is broken, not that the app is in some other legitimate
    /// state. Leaving it as a bare `if` made that failure silent, and the
    /// polling loops in `RealWADTests`/`DemoLoopReplayTests` would then spin
    /// against the wrong screen until their deadline and report the timeout
    /// instead of the real cause. `Scripts/capture-screenshots.sh` depends on
    /// this assertion outright: it shoots straight after returning, so a silent
    /// no-op there produces a correctly-named marketing image of the wrong
    /// screen (see issue #156).
    func returnToShelf(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.navigationBars.buttons["Waddle"]
        XCTAssertTrue(back.waitForExistence(timeout: 5),
                      "no back button out of Manage — navigation is broken",
                      file: file, line: line)
        back.tap()
        XCTAssertTrue(app.buttons["manageButton"].waitForExistence(timeout: 10),
                      "left Manage but never landed back on the shelf",
                      file: file, line: line)
    }
}
