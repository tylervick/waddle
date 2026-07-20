import XCTest
@testable import WADdle

final class TouchControlSchemeTests: XCTestCase {

    // MARK: Default + persistence key

    func testDefaultSchemeIsClassic() {
        XCTAssertEqual(TouchControlScheme.defaultScheme, .classic)
    }

    func testCurrentFallsBackToDefaultWhenUnset() {
        withEmptyDefaults { defaults in
            XCTAssertEqual(TouchControlScheme.current(defaults: defaults), .classic)
        }
    }

    func testCurrentFallsBackToDefaultWhenUnrecognized() {
        withEmptyDefaults { defaults in
            defaults.set("not-a-real-scheme", forKey: TouchControlScheme.userDefaultsKey)
            XCTAssertEqual(TouchControlScheme.current(defaults: defaults), .classic)
        }
    }

    func testCurrentReadsPersistedModern() {
        withEmptyDefaults { defaults in
            defaults.set(TouchControlScheme.modern.rawValue, forKey: TouchControlScheme.userDefaultsKey)
            XCTAssertEqual(TouchControlScheme.current(defaults: defaults), .modern)
        }
    }

    func testCurrentReadsPersistedClassic() {
        withEmptyDefaults { defaults in
            defaults.set(TouchControlScheme.classic.rawValue, forKey: TouchControlScheme.userDefaultsKey)
            XCTAssertEqual(TouchControlScheme.current(defaults: defaults), .classic)
        }
    }

    // MARK: usesDragTurn

    func testClassicHasNoDragTurn() {
        XCTAssertFalse(TouchControlScheme.classic.usesDragTurn)
    }

    func testModernHasDragTurn() {
        XCTAssertTrue(TouchControlScheme.modern.usesDragTurn)
    }

    // MARK: axisMapping -- classic (turn lives on the stick)

    func testClassicRoutesStickXToRightXNotLeftX() {
        let mapping = TouchControlScheme.classic.axisMapping(stickX: 0.7, stickY: -0.5)
        XCTAssertEqual(mapping.leftX, 0, "classic must not drive a strafe axis")
        XCTAssertEqual(mapping.rightX, 0.7, "classic routes horizontal deflection to Woof's turn axis")
    }

    func testClassicRoutesStickYToLeftY() {
        let mapping = TouchControlScheme.classic.axisMapping(stickX: 0.7, stickY: -0.5)
        XCTAssertEqual(mapping.leftY, -0.5)
    }

    func testClassicNeutralStickIsAllZero() {
        let mapping = TouchControlScheme.classic.axisMapping(stickX: 0, stickY: 0)
        XCTAssertEqual(mapping, TouchAxisMapping(leftX: 0, leftY: 0, rightX: 0))
    }

    // MARK: axisMapping -- modern (twin-stick strafe, turn is a separate drag)

    func testModernRoutesStickXToLeftX() {
        let mapping = TouchControlScheme.modern.axisMapping(stickX: 0.7, stickY: -0.5)
        XCTAssertEqual(mapping.leftX, 0.7)
        XCTAssertEqual(mapping.leftY, -0.5)
    }

    func testModernNeverDrivesRightX() {
        let mapping = TouchControlScheme.modern.axisMapping(stickX: 0.7, stickY: -0.5)
        XCTAssertEqual(mapping.rightX, 0, "modern's turn is the separate drag accumulator, not RIGHTX")
    }

    func testModernNeutralStickIsAllZero() {
        let mapping = TouchControlScheme.modern.axisMapping(stickX: 0, stickY: 0)
        XCTAssertEqual(mapping, TouchAxisMapping(leftX: 0, leftY: 0, rightX: 0))
    }

    // MARK: Helpers

    /// Runs `body` against a throwaway, uniquely-named UserDefaults suite,
    /// cleaned up via `defer` (not XCTest's `addTeardownBlock`, whose
    /// escaping closure crossing an isolation boundary trips Swift 6's
    /// strict-concurrency "sending risks data races" check on the captured
    /// UserDefaults instance).
    private func withEmptyDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "TouchControlSchemeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
