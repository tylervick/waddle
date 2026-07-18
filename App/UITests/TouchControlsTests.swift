import XCTest

/// Proves the touch overlay installs over a live engine session and that
/// stick/button/turn gestures actually reach SDL (via the shim's debug
/// counter, surfaced post-session when BOOMBOX_DEBUG_INPUT_COUNTS is set).
final class TouchControlsTests: XCTestCase {

    @MainActor
    func testOverlayInstallsAndInputsReachEngine() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BOOMBOX_AUTOQUIT_SECONDS"] = "14"
        app.launchEnvironment["BOOMBOX_DEBUG_INPUT_COUNTS"] = "1"
        // The Simulator's XCUITest automation session registers a phantom
        // GCController and reports GCKeyboard.coalesced non-nil (the host
        // Mac's own keyboard) for the whole session, which correctly -- but
        // unhelpfully here -- triggers OverlayPresenter's "hide touch
        // overlay when physical input is present" policy (Task 5) and makes
        // the overlay permanently inaccessible to this test. Force it
        // visible; see OverlayPresenter.applyPolicy().
        app.launchEnvironment["BOOMBOX_FORCE_TOUCH_OVERLAY"] = "1"
        app.launch()

        let play = app.buttons["playFreedoom1"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()

        // Overlay appears once the engine window exists.
        let fire = app.buttons["fireButton"]
        XCTAssertTrue(fire.waitForExistence(timeout: 20), "overlay never installed")

        // Button press (down+up).
        fire.tap()
        app.buttons["useButton"].tap()

        // Movement stick: press in the left 40% and drag.
        let stickStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.7))
        let stickEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.55))
        stickStart.press(forDuration: 0.1, thenDragTo: stickEnd)

        // Turn drag on the right half.
        let turnStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        let turnEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        turnStart.press(forDuration: 0.05, thenDragTo: turnEnd)

        // Session ends via autoquit; overlay must be gone, launcher back.
        let exitLabel = app.staticTexts["engineExitLabel"]
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90))
        XCTAssertEqual(exitLabel.label, "Engine exited: 0")
        XCTAssertFalse(fire.exists, "overlay not torn down after session")

        // The shim must have seen our gestures.
        let countLabel = app.staticTexts["touchEventCountLabel"]
        XCTAssertTrue(countLabel.waitForExistence(timeout: 5))
        let count = Int(countLabel.label.replacingOccurrences(
            of: "touchEvents: ", with: "")) ?? 0
        XCTAssertGreaterThan(count, 0, "no touch input reached the SDL shim")
    }

    /// Classic is the default scheme (usesDragTurn == false), so the test
    /// above never exercises the right-side drag-to-turn gesture at all --
    /// touchesBegan silently ignores it. This test pins the scheme to
    /// modern via the BOOMBOX_TOUCH_SCHEME test seam (see
    /// TouchControlScheme.current()) and performs *only* the turn drag --
    /// no buttons, no stick -- so the shim's event count can only have come
    /// from the drag-turn path, isolating it from the button/stick
    /// coverage above.
    @MainActor
    func testModernSchemeDragTurnReachesEngine() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BOOMBOX_AUTOQUIT_SECONDS"] = "14"
        app.launchEnvironment["BOOMBOX_DEBUG_INPUT_COUNTS"] = "1"
        app.launchEnvironment["BOOMBOX_FORCE_TOUCH_OVERLAY"] = "1"
        app.launchEnvironment["BOOMBOX_TOUCH_SCHEME"] = "modern"
        app.launch()

        let play = app.buttons["playFreedoom1"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()

        // Overlay appears once the engine window exists.
        let fire = app.buttons["fireButton"]
        XCTAssertTrue(fire.waitForExistence(timeout: 20), "overlay never installed")

        // Turn drag on the right half -- the only gesture this test performs.
        let turnStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        let turnEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        turnStart.press(forDuration: 0.05, thenDragTo: turnEnd)

        // Session ends via autoquit; overlay must be gone, launcher back.
        let exitLabel = app.staticTexts["engineExitLabel"]
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90))
        XCTAssertEqual(exitLabel.label, "Engine exited: 0")
        XCTAssertFalse(fire.exists, "overlay not torn down after session")

        // The shim must have seen the drag-turn gesture, and only that.
        let countLabel = app.staticTexts["touchEventCountLabel"]
        XCTAssertTrue(countLabel.waitForExistence(timeout: 5))
        let count = Int(countLabel.label.replacingOccurrences(
            of: "touchEvents: ", with: "")) ?? 0
        XCTAssertGreaterThan(count, 0, "modern-scheme drag-turn never reached the SDL shim")
    }

    /// Regression test for a device-testing bug: FIRE autofired forever
    /// in-game after a single press. Root cause: the virtual joystick's
    /// auto-mapping exposes triggers as full-range axes, so writing a
    /// scaled-float release (0.0) left the gamepad-layer RIGHT_TRIGGER
    /// value at ~50% -- permanently above Woof's trigger_threshold (see
    /// the WoofIOS_SetTouchTrigger doc comment in woof_ios.c for the full
    /// citation trail). BOOMBOX_TEST_WARP puts the session in-game (no
    /// scripted menu navigation) so FIRE exercises its real gameplay path,
    /// not the title screen's menu-select behavior. Classic scheme (the
    /// default) is fine here -- FIRE is scheme-independent.
    @MainActor
    func testFireReleaseClearsTriggerResidue() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BOOMBOX_AUTOQUIT_SECONDS"] = "14"
        app.launchEnvironment["BOOMBOX_DEBUG_INPUT_COUNTS"] = "1"
        app.launchEnvironment["BOOMBOX_FORCE_TOUCH_OVERLAY"] = "1"
        app.launchEnvironment["BOOMBOX_TEST_WARP"] = "1"
        app.launch()

        let play = app.buttons["playFreedoom1"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()

        let fire = app.buttons["fireButton"]
        XCTAssertTrue(fire.waitForExistence(timeout: 20), "overlay never installed")

        // A real down+up: press(forDuration:) synthesizes touchesBegan,
        // holds, then touchesEnded -- OverlayButton's onPress(true) then
        // onPress(false), same as a real fingertip tap-and-release.
        fire.press(forDuration: 0.2)

        // Also exercise the MAP fix (NORTH, not the unbound BACK) while
        // we're in-game; not this test's core assertion, just confirms the
        // button wiring doesn't crash the session.
        app.buttons["automapButton"].tap()

        // Session ends via autoquit; the ~0.3s post-release telemetry
        // sample (TouchGamepad.setFireTrigger) has long since landed by
        // the time this fires.
        let exitLabel = app.staticTexts["engineExitLabel"]
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90))
        XCTAssertEqual(exitLabel.label, "Engine exited: 0")

        let residueLabel = app.staticTexts["triggerResidueLabel"]
        XCTAssertTrue(residueLabel.waitForExistence(timeout: 5),
                      "no trigger-residue telemetry sampled")
        let residue = Float(residueLabel.label.replacingOccurrences(
            of: "triggerResidue: ", with: "")) ?? 999
        XCTAssertLessThanOrEqual(residue, 0.05,
            "FIRE trigger still reads \(residue) after release -- autofire regression")
    }
}
