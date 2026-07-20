import XCTest
@testable import BoomBox

final class TouchTuningTests: XCTestCase {

    // MARK: Defaults + keys (the keys are the @AppStorage contract — renaming
    // one silently orphans every user's saved value, so they're pinned here)

    func testDefaultValues() {
        XCTAssertEqual(TouchTuning.default.turnSpeed, 1.0)
        // 0: the engine already applies its own radial deadzone to gamepad
        // axes; an app-side default would stack on top (see TouchTuning).
        XCTAssertEqual(TouchTuning.default.stickDeadZone, 0.0)
        XCTAssertEqual(TouchTuning.default.moveSensitivity, 1.0)
    }

    func testUserDefaultsKeys() {
        XCTAssertEqual(TouchTuning.turnSpeedKey, "turnSpeed")
        XCTAssertEqual(TouchTuning.stickDeadZoneKey, "stickDeadZone")
        XCTAssertEqual(TouchTuning.moveSensitivityKey, "moveSensitivity")
    }

    func testSliderRanges() {
        XCTAssertEqual(TouchTuning.turnSpeedRange, 0.25...3.0)
        XCTAssertEqual(TouchTuning.stickDeadZoneRange, 0.0...0.4)
        XCTAssertEqual(TouchTuning.moveSensitivityRange, 0.5...1.5)
    }

    // MARK: current(defaults:) — reads, falls back, clamps

    func testCurrentFallsBackToDefaultsWhenUnset() {
        withEmptyDefaults { defaults in
            XCTAssertEqual(TouchTuning.current(defaults: defaults), .default)
        }
    }

    func testCurrentReadsPersistedValues() {
        withEmptyDefaults { defaults in
            defaults.set(2.0, forKey: TouchTuning.turnSpeedKey)
            defaults.set(0.1, forKey: TouchTuning.stickDeadZoneKey)
            defaults.set(1.25, forKey: TouchTuning.moveSensitivityKey)
            let tuning = TouchTuning.current(defaults: defaults)
            XCTAssertEqual(tuning.turnSpeed, 2.0)
            XCTAssertEqual(tuning.stickDeadZone, 0.1)
            XCTAssertEqual(tuning.moveSensitivity, 1.25)
        }
    }

    func testCurrentClampsValuesAboveRange() {
        withEmptyDefaults { defaults in
            defaults.set(99.0, forKey: TouchTuning.turnSpeedKey)
            defaults.set(0.9, forKey: TouchTuning.stickDeadZoneKey)
            defaults.set(7.0, forKey: TouchTuning.moveSensitivityKey)
            let tuning = TouchTuning.current(defaults: defaults)
            XCTAssertEqual(tuning.turnSpeed, 3.0)
            XCTAssertEqual(tuning.stickDeadZone, 0.4)
            XCTAssertEqual(tuning.moveSensitivity, 1.5)
        }
    }

    func testCurrentClampsValuesBelowRange() {
        withEmptyDefaults { defaults in
            defaults.set(0.01, forKey: TouchTuning.turnSpeedKey)
            defaults.set(-1.0, forKey: TouchTuning.stickDeadZoneKey)
            defaults.set(0.0, forKey: TouchTuning.moveSensitivityKey)
            let tuning = TouchTuning.current(defaults: defaults)
            XCTAssertEqual(tuning.turnSpeed, 0.25)
            XCTAssertEqual(tuning.stickDeadZone, 0.0)
            XCTAssertEqual(tuning.moveSensitivity, 0.5)
        }
    }

    func testCurrentIgnoresNonNumericGarbage() {
        withEmptyDefaults { defaults in
            defaults.set("banana", forKey: TouchTuning.turnSpeedKey)
            defaults.set(["not": "a number"], forKey: TouchTuning.stickDeadZoneKey)
            XCTAssertEqual(TouchTuning.current(defaults: defaults), .default)
        }
    }

    // MARK: apply(to:) — axis scaling

    func testApplyAtDefaultsIsIdentity() {
        let mapping = TouchAxisMapping(leftX: 0.3, leftY: -0.6, rightX: 0.4)
        XCTAssertEqual(TouchTuning.default.apply(to: mapping), mapping)
    }

    func testApplyScalesRightXByTurnSpeed() {
        let tuning = TouchTuning(turnSpeed: 2.0, stickDeadZone: 0.2, moveSensitivity: 1.0)
        let scaled = tuning.apply(to: TouchAxisMapping(leftX: 0, leftY: -0.5, rightX: 0.4))
        XCTAssertEqual(scaled.rightX, 0.8, accuracy: 0.0001)
        XCTAssertEqual(scaled.leftY, -0.5, accuracy: 0.0001, "turnSpeed must not touch movement")
    }

    func testApplyScalesLeftAxesByMoveSensitivity() {
        let tuning = TouchTuning(turnSpeed: 1.0, stickDeadZone: 0.2, moveSensitivity: 1.5)
        let scaled = tuning.apply(to: TouchAxisMapping(leftX: 0.4, leftY: -0.6, rightX: 0.2))
        XCTAssertEqual(scaled.leftX, 0.6, accuracy: 0.0001)
        XCTAssertEqual(scaled.leftY, -0.9, accuracy: 0.0001)
        XCTAssertEqual(scaled.rightX, 0.2, accuracy: 0.0001, "moveSensitivity must not touch turn")
    }

    func testApplyClampsScaledAxesToUnitRange() {
        let tuning = TouchTuning(turnSpeed: 3.0, stickDeadZone: 0.2, moveSensitivity: 1.5)
        let positive = tuning.apply(to: TouchAxisMapping(leftX: 0.9, leftY: 0.9, rightX: 0.5))
        XCTAssertEqual(positive.leftX, 1.0)
        XCTAssertEqual(positive.leftY, 1.0)
        XCTAssertEqual(positive.rightX, 1.0)
        let negative = tuning.apply(to: TouchAxisMapping(leftX: -0.9, leftY: -0.9, rightX: -0.5))
        XCTAssertEqual(negative.leftX, -1.0)
        XCTAssertEqual(negative.leftY, -1.0)
        XCTAssertEqual(negative.rightX, -1.0)
    }

    func testApplyKeepsNeutralNeutral() {
        let tuning = TouchTuning(turnSpeed: 3.0, stickDeadZone: 0.4, moveSensitivity: 1.5)
        let scaled = tuning.apply(to: TouchAxisMapping(leftX: 0, leftY: 0, rightX: 0))
        XCTAssertEqual(scaled, TouchAxisMapping(leftX: 0, leftY: 0, rightX: 0))
    }

    // MARK: modern-scheme drag turn

    func testScaledTurnSensitivityMultipliesBase() {
        let tuning = TouchTuning(turnSpeed: 2.0, stickDeadZone: 0.2, moveSensitivity: 1.0)
        XCTAssertEqual(tuning.scaledTurnSensitivity(base: 1.5), 3.0, accuracy: 0.0001)
    }

    func testScaledTurnSensitivityAtDefaultIsBase() {
        XCTAssertEqual(TouchTuning.default.scaledTurnSensitivity(base: 1.5), 1.5, accuracy: 0.0001)
    }

    // MARK: Helpers

    /// Same throwaway-suite pattern as TouchControlSchemeTests (defer, not
    /// addTeardownBlock, for Swift 6 strict-concurrency reasons documented
    /// there).
    private func withEmptyDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "TouchTuningTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
