import XCTest
@testable import Waddle

final class TouchControlSchemeTests: XCTestCase {

    // MARK: Default + persistence key

    func testDefaultSchemeIsModern() {
        XCTAssertEqual(TouchControlScheme.defaultScheme, .modern)
    }

    func testCurrentFallsBackToDefaultWhenUnset() {
        withEmptyDefaults { defaults in
            XCTAssertEqual(TouchControlScheme.current(defaults: defaults), .modern)
        }
    }

    func testCurrentFallsBackToDefaultWhenUnrecognized() {
        withEmptyDefaults { defaults in
            defaults.set("not-a-real-scheme", forKey: TouchControlScheme.userDefaultsKey)
            XCTAssertEqual(TouchControlScheme.current(defaults: defaults), .modern)
        }
    }

    // MARK: Settling the stored scheme at launch (issue #534)

    /// The scheme an install with nothing stored played on before the
    /// default changed. Pinned on its own so that a later change to
    /// `defaultScheme` cannot drag it along.
    func testPreviousDefaultIsClassic() {
        XCTAssertEqual(TouchControlScheme.previousDefault, .classic)
    }

    func testANewInstallStartsOnModern() {
        withEmptyDefaults { defaults in
            TouchControlScheme.settleStoredScheme(isExistingInstall: false, defaults: defaults)
            XCTAssertEqual(TouchControlScheme.current(defaults: defaults), .modern)
            XCTAssertEqual(defaults.string(forKey: TouchControlScheme.userDefaultsKey), "modern",
                           "a new install's scheme must be stored, so its next launch is not mistaken for an old install")
        }
    }

    /// The player who never opened Settings and has been on Classic by
    /// default: they stay on Classic.
    func testAnExistingInstallThatNeverChoseKeepsClassic() {
        withEmptyDefaults { defaults in
            TouchControlScheme.settleStoredScheme(isExistingInstall: true, defaults: defaults)
            XCTAssertEqual(TouchControlScheme.current(defaults: defaults), .classic)
        }
    }

    /// An unrecognized stored value read as the default, Classic, before.
    func testAnExistingInstallWithAnUnrecognizedValueKeepsClassic() {
        withEmptyDefaults { defaults in
            defaults.set("not-a-real-scheme", forKey: TouchControlScheme.userDefaultsKey)
            TouchControlScheme.settleStoredScheme(isExistingInstall: true, defaults: defaults)
            XCTAssertEqual(TouchControlScheme.current(defaults: defaults), .classic)
        }
    }

    func testAnExistingInstallThatChoseKeepsItsChoice() {
        for chosen in TouchControlScheme.allCases {
            withEmptyDefaults { defaults in
                defaults.set(chosen.rawValue, forKey: TouchControlScheme.userDefaultsKey)
                TouchControlScheme.settleStoredScheme(isExistingInstall: true, defaults: defaults)
                XCTAssertEqual(TouchControlScheme.current(defaults: defaults), chosen)
            }
        }
    }

    /// A new install's second launch has a library, so it reads as an
    /// existing install; it must stay on Modern rather than be pinned to
    /// Classic then.
    func testANewInstallStaysOnModernAtItsNextLaunch() {
        withEmptyDefaults { defaults in
            TouchControlScheme.settleStoredScheme(isExistingInstall: false, defaults: defaults)
            TouchControlScheme.settleStoredScheme(isExistingInstall: true, defaults: defaults)
            XCTAssertEqual(TouchControlScheme.current(defaults: defaults), .modern)
        }
    }

    /// The setting still switches both ways after settling, on either kind
    /// of install, and a later launch's settle leaves the choice alone.
    func testTheSettingStillSwitchesBothWaysAfterSettling() {
        for existing in [false, true] {
            withEmptyDefaults { defaults in
                TouchControlScheme.settleStoredScheme(isExistingInstall: existing, defaults: defaults)
                for chosen in [TouchControlScheme.classic, .modern, .classic] {
                    defaults.set(chosen.rawValue, forKey: TouchControlScheme.userDefaultsKey)
                    TouchControlScheme.settleStoredScheme(isExistingInstall: true, defaults: defaults)
                    XCTAssertEqual(TouchControlScheme.current(defaults: defaults), chosen,
                                   "existing install: \(existing)")
                }
            }
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

    // MARK: Per-item effective override

    func testEffectiveOverrideWinsOverGlobalDefault() {
        withEmptyDefaults { defaults in
            defaults.set(TouchControlScheme.classic.rawValue, forKey: TouchControlScheme.userDefaultsKey)
            XCTAssertEqual(
                TouchControlScheme.effective(override: TouchControlScheme.modern.rawValue, defaults: defaults),
                .modern)
        }
    }

    func testEffectiveNilOverrideFallsToGlobal() {
        withEmptyDefaults { defaults in
            defaults.set(TouchControlScheme.modern.rawValue, forKey: TouchControlScheme.userDefaultsKey)
            XCTAssertEqual(TouchControlScheme.effective(override: nil, defaults: defaults), .modern)
        }
    }

    func testEffectiveInvalidOverrideFallsToGlobal() {
        withEmptyDefaults { defaults in
            defaults.set(TouchControlScheme.classic.rawValue, forKey: TouchControlScheme.userDefaultsKey)
            XCTAssertEqual(TouchControlScheme.effective(override: "bogus", defaults: defaults), .classic)
        }
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
