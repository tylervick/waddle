import XCTest

extension XCTestCase {
    /// Taps a text field, clears any existing contents, and types `text`.
    /// Shared by the preset-creation / edit / RealWAD UI flows.
    ///
    /// Taps the trailing edge so the caret lands at the end before
    /// backspacing — a centre tap lands mid-string in a narrow alert field.
    func clearAndType(_ field: XCUIElement, _ text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        if let existing = field.value as? String, !existing.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(text)
    }

    /// Opens a tile's game page via its long-press menu (spec §3.1).
    func openGamePage(_ app: XCUIApplication, tile tileID: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        let tile = app.buttons[tileID]
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "tile \(tileID) missing", file: file, line: line)
        tile.press(forDuration: 1.0)
        app.buttons["Details"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "gamePage").firstMatch
            .waitForExistence(timeout: 5), "game page never appeared", file: file, line: line)
    }

    /// Pops the game page back to the shelf. The back button is titled with the
    /// shelf's own navigation title. Asserts, so a broken pop fails here rather
    /// than as a timeout against the wrong screen later.
    func returnToShelf(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.navigationBars.buttons["Waddle"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no back button — navigation is broken", file: file, line: line)
        back.tap()
        XCTAssertTrue(app.buttons["importButton"].waitForExistence(timeout: 10),
                      "left the page but never landed back on the shelf", file: file, line: line)
    }

    /// Opens Settings → Files (spec §3.3).
    func openFiles(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let gear = app.buttons["touchSchemeMenu"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "gear missing", file: file, line: line)
        gear.tap()
        let files = app.buttons["filesButton"]
        XCTAssertTrue(files.waitForExistence(timeout: 5), "Files row missing from Settings", file: file, line: line)
        files.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "filesScreen").firstMatch
            .waitForExistence(timeout: 5), "Files screen never appeared", file: file, line: line)
    }

    /// Closes Settings (from Files or its root) back to the shelf.
    func closeSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.navigationBars.buttons["Settings"]
        if back.waitForExistence(timeout: 2) { back.tap() }
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Settings Done missing", file: file, line: line)
        done.tap()
        XCTAssertTrue(app.buttons["importButton"].waitForExistence(timeout: 10), file: file, line: line)
    }

    /// Scrolls until `element` is in the accessibility tree. A lazy `Form`/`List`
    /// omits off-screen rows entirely (docs/learnings/lazy-form-hides-rows-from-uitests.md).
    func scrollTo(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 6,
                  file: StaticString = #filePath, line: UInt = #line) {
        var swipes = 0
        while !element.exists && swipes < maxSwipes { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(element.waitForExistence(timeout: 2), "\(element) never scrolled into view", file: file, line: line)
    }

    /// The Rename alert's text field. SwiftUI does not forward an
    /// `accessibilityIdentifier` set on an alert's `TextField`, so it is found
    /// through the alert itself.
    func renameField(in app: XCUIApplication) -> XCUIElement {
        app.alerts["Rename"].textFields.firstMatch
    }
}
