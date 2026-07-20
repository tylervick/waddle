import XCTest

/// Proves the touch overlay installs over a live engine session and that
/// stick/button/turn gestures actually reach SDL (via the shim's debug
/// counter, surfaced post-session when WADDLE_DEBUG_INPUT_COUNTS is set).
final class TouchControlsTests: XCTestCase {

    @MainActor
    func testOverlayInstallsAndInputsReachEngine() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "14"
        app.launchEnvironment["WADDLE_DEBUG_INPUT_COUNTS"] = "1"
        // The Simulator's XCUITest automation session registers a phantom
        // GCController and reports GCKeyboard.coalesced non-nil (the host
        // Mac's own keyboard) for the whole session, which correctly -- but
        // unhelpfully here -- triggers OverlayPresenter's "hide touch
        // overlay when physical input is present" policy (Task 5) and makes
        // the overlay permanently inaccessible to this test. Force it
        // visible; see OverlayPresenter.applyPolicy().
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
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
    /// modern via the WADDLE_TOUCH_SCHEME test seam (see
    /// TouchControlScheme.current()) and performs *only* the turn drag --
    /// no buttons, no stick -- so the shim's event count can only have come
    /// from the drag-turn path, isolating it from the button/stick
    /// coverage above.
    @MainActor
    func testModernSchemeDragTurnReachesEngine() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "14"
        app.launchEnvironment["WADDLE_DEBUG_INPUT_COUNTS"] = "1"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launchEnvironment["WADDLE_TOUCH_SCHEME"] = "modern"
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
    /// citation trail). WADDLE_TEST_WARP puts the session in-game (no
    /// scripted menu navigation) so FIRE exercises its real gameplay path,
    /// not the title screen's menu-select behavior. Classic scheme (the
    /// default) is fine here -- FIRE is scheme-independent.
    @MainActor
    func testFireReleaseClearsTriggerResidue() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "14"
        app.launchEnvironment["WADDLE_DEBUG_INPUT_COUNTS"] = "1"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launchEnvironment["WADDLE_TEST_WARP"] = "1"
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

    /// All-orientations support (Plan 4 Task 7b): a session started in
    /// portrait must survive rotating to landscape and back. SDL's iOS
    /// backend forwards rotations to Woof! as window-resize events (Woof
    /// re-letterboxes, same as a desktop window resize), and the overlay's
    /// autoresizingMask + proportional layoutSubviews must follow the new
    /// bounds -- so after each rotation FIRE is tapped again, and the
    /// post-session shim event count proves post-rotation touches still
    /// reached SDL at the repositioned coordinates. "Survives" is asserted
    /// via the engineExitLabel protocol: the armed autoquit ends the session
    /// with exit code 0 only if the engine is still running normally after
    /// both rotations (a mid-session crash would kill the app and fail the
    /// waits below instead).
    @MainActor
    func testSessionSurvivesRotation() throws {
        // Explicit start orientation: the suite shares a simulator, so don't
        // inherit whatever a previous test (or the screenshot script) left.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "25"
        app.launchEnvironment["WADDLE_DEBUG_INPUT_COUNTS"] = "1"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launch()

        let play = app.buttons["playFreedoom1"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))

        // Environmental guard: on some simulators XCUIDevice's orientation
        // setter silently never rotates the *interface* (observed on an
        // iPhone 17 Pro simulator whose window carried a stale stored
        // rotation — the identical run passed on iPhone 17 Pro Max). Probe
        // with the plain SwiftUI launcher first: if even that doesn't
        // rotate, the simulator can't exercise this test at all — skip
        // rather than fail. If the launcher rotates but the session later
        // doesn't, that's the app bug this test exists to catch — fail.
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2)
        let launcherRotates = app.frame.width > app.frame.height
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 2)
        try XCTSkipUnless(launcherRotates,
            "this simulator does not perform interface rotation; run on one that does")

        play.tap()

        let fire = app.buttons["fireButton"]
        XCTAssertTrue(fire.waitForExistence(timeout: 20), "overlay never installed")
        attachScreenshot(named: "session-portrait")

        XCTAssertLessThan(app.frame.width, app.frame.height,
                          "session did not start with a portrait interface")

        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2) // let SDL deliver + Woof apply the resize
        XCTAssertGreaterThan(app.frame.width, app.frame.height,
                             "interface did not rotate to landscape mid-session")
        XCTAssertTrue(fire.isHittable, "FIRE not hittable after portrait -> landscape")
        fire.tap()
        attachScreenshot(named: "session-landscape")

        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 2)
        XCTAssertLessThan(app.frame.width, app.frame.height,
                          "interface did not rotate back to portrait mid-session")
        XCTAssertTrue(fire.isHittable, "FIRE not hittable after landscape -> portrait")
        fire.tap()
        attachScreenshot(named: "session-portrait-back")

        let exitLabel = app.staticTexts["engineExitLabel"]
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90),
                      "session did not survive rotation to a clean autoquit")
        XCTAssertEqual(exitLabel.label, "Engine exited: 0")
        XCTAssertFalse(fire.exists, "overlay not torn down after session")

        let countLabel = app.staticTexts["touchEventCountLabel"]
        XCTAssertTrue(countLabel.waitForExistence(timeout: 5))
        let count = Int(countLabel.label.replacingOccurrences(
            of: "touchEvents: ", with: "")) ?? 0
        XCTAssertGreaterThan(count, 0, "post-rotation touches never reached the SDL shim")
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
