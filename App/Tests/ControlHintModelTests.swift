import XCTest
@testable import Waddle

/// When the overlay's control hints are on screen (issue #392): four idle
/// seconds while the weapon selector could open, gone on the next
/// touch-down, never with the setting off, and Move/Aim only in the Modern
/// scheme. Pure, so no simulator session is involved.
final class ControlHintModelTests: XCTestCase {
    private let weaponsOnly = ControlHintModel.Hints(weapons: true, moveAndAim: false)
    private let all = ControlHintModel.Hints(weapons: true, moveAndAim: true)

    private func model(enabled: Bool = true, scheme: TouchControlScheme = .classic) -> ControlHintModel {
        ControlHintModel(enabled: enabled, scheme: scheme)
    }

    func testTheDelayIsFourSeconds() {
        XCTAssertEqual(ControlHintModel.idleDelay, 4)
    }

    func testHiddenBeforeTheFirstTick() {
        XCTAssertEqual(model().hints, .hidden)
    }

    func testHiddenBeforeFourSecondsAndVisibleAtFour() {
        var m = model()
        m.tick(at: 100, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, .hidden, "the count starts at the first idle tick")
        m.tick(at: 103.75, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, .hidden)
        m.tick(at: 104, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, weaponsOnly)
        m.tick(at: 110, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, weaponsOnly, "it stays up while nothing happens")
    }

    func testATouchDownHidesItAtOnceAndRestartsTheCount() {
        var m = model()
        m.tick(at: 100, canOpen: true, touching: false)
        m.tick(at: 104, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, weaponsOnly)

        m.touchDown()
        XCTAssertEqual(m.hints, .hidden, "hidden by the touch-down itself, before any tick")
        // A tap: the finger is already up again at the next tick, which is
        // where the new count starts.
        m.tick(at: 105.25, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, .hidden)
        m.tick(at: 109, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, .hidden, "four seconds from the first idle tick, not from the old count")
        m.tick(at: 109.25, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, weaponsOnly)
    }

    func testATouchDownBeforeItShowsRestartsTheCount() {
        var m = model()
        m.tick(at: 100, canOpen: true, touching: false)
        m.touchDown()
        m.tick(at: 104, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, .hidden)
        m.tick(at: 107.75, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, .hidden)
        m.tick(at: 108, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, weaponsOnly)
    }

    /// A held finger (the stick, FIRE) is not idleness however long it has
    /// been down: the count starts when it lifts.
    func testNeverVisibleWhileAFingerIsDown() {
        var m = model()
        m.touchDown()
        for t in stride(from: 100.25, through: 120, by: 0.25) {
            m.tick(at: t, canOpen: true, touching: true)
            XCTAssertEqual(m.hints, .hidden, "at \(t)")
        }
        // The finger lifted somewhere between 120 and 120.25. Counting from
        // the last held tick would show the hint a quarter-second early.
        m.tick(at: 120.25, canOpen: true, touching: false)
        m.tick(at: 124, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, .hidden, "four whole idle seconds, counted from the first idle tick")
        m.tick(at: 124.25, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, weaponsOnly)
    }

    func testNeverVisibleWhileTheSelectorCannotOpen() {
        var m = model(scheme: .modern)
        for t in stride(from: 100.0, through: 130, by: 0.25) {
            m.tick(at: t, canOpen: false, touching: false)
            XCTAssertEqual(m.hints, .hidden, "at \(t)")
        }
    }

    /// A menu, the automap or the selector itself opening takes the hint
    /// down, and closing it does not bring the hint straight back.
    func testLosingTheSelectorHidesItAndRestartsTheCount() {
        var m = model()
        m.tick(at: 100, canOpen: true, touching: false)
        m.tick(at: 104, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, weaponsOnly)
        m.tick(at: 104.25, canOpen: false, touching: false)
        XCTAssertEqual(m.hints, .hidden)
        m.tick(at: 110, canOpen: false, touching: false)
        m.tick(at: 110.25, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, .hidden, "the idle time under the menu does not count")
        m.tick(at: 114, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, .hidden, "nor does the part-tick before it closed")
        m.tick(at: 114.25, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, weaponsOnly)
    }

    func testNeverVisibleWithTheSettingOff() {
        for scheme in TouchControlScheme.allCases {
            var m = model(enabled: false, scheme: scheme)
            for t in stride(from: 100.0, through: 130, by: 0.25) {
                m.tick(at: t, canOpen: true, touching: false)
                XCTAssertEqual(m.hints, .hidden, "\(scheme) at \(t)")
            }
        }
    }

    func testModernAddsMoveAndAim() {
        var m = model(scheme: .modern)
        m.tick(at: 100, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, .hidden)
        m.tick(at: 104, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, all)
        m.touchDown()
        XCTAssertEqual(m.hints, .hidden, "Move and Aim leave with Weapons")
    }

    func testClassicShowsWeaponsAlone() {
        var m = model(scheme: .classic)
        m.tick(at: 100, canOpen: true, touching: false)
        m.tick(at: 104, canOpen: true, touching: false)
        XCTAssertEqual(m.hints, weaponsOnly, "Classic has no aim side to label")
    }

    // MARK: The setting

    func testSettingKeysAreStable() {
        XCTAssertEqual(ControlHintsSetting.userDefaultsKey, "showControlHints")
        XCTAssertEqual(ControlHintsSetting.environmentKey, "WADDLE_CONTROL_HINTS")
    }

    func testSettingIsOnByDefault() {
        XCTAssertTrue(ControlHintsSetting.defaultValue)
        withEmptyDefaults { defaults in
            XCTAssertTrue(ControlHintsSetting.current(defaults: defaults, environment: [:]))
        }
    }

    func testSettingReadsThePersistedValue() {
        withEmptyDefaults { defaults in
            defaults.set(false, forKey: ControlHintsSetting.userDefaultsKey)
            XCTAssertFalse(ControlHintsSetting.current(defaults: defaults, environment: [:]))
            defaults.set(true, forKey: ControlHintsSetting.userDefaultsKey)
            XCTAssertTrue(ControlHintsSetting.current(defaults: defaults, environment: [:]))
        }
    }

    #if DEBUG
    func testEnvironmentOverrideWinsOverThePersistedValue() {
        withEmptyDefaults { defaults in
            defaults.set(true, forKey: ControlHintsSetting.userDefaultsKey)
            XCTAssertFalse(ControlHintsSetting.current(defaults: defaults,
                                                       environment: ["WADDLE_CONTROL_HINTS": "0"]))
            defaults.set(false, forKey: ControlHintsSetting.userDefaultsKey)
            XCTAssertTrue(ControlHintsSetting.current(defaults: defaults,
                                                      environment: ["WADDLE_CONTROL_HINTS": "1"]))
        }
    }

    func testUnrecognizedEnvironmentOverrideIsIgnored() {
        withEmptyDefaults { defaults in
            defaults.set(false, forKey: ControlHintsSetting.userDefaultsKey)
            XCTAssertFalse(ControlHintsSetting.current(defaults: defaults,
                                                       environment: ["WADDLE_CONTROL_HINTS": "yes"]))
        }
    }
    #endif

    // MARK: Helpers

    /// A throwaway, uniquely named suite, as `WeaponSelectorStyleTests` uses.
    private func withEmptyDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "ControlHintModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
