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
}
