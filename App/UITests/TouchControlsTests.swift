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

    /// touch_event_count (woof_ios.c) is a process-lifetime static fed by
    /// all four touch-shim entry points, and the debug HUD reads it after
    /// each session. It must be reset at session *start* -- near the
    /// I_ResetErrorMessages call, not in the setjmp-unwind branch, which
    /// runs at session exit before ContentView reads the count and would
    /// make the count > 0 assertions in the tests above impossible -- so a
    /// fresh session's count reflects only its own input, not a running
    /// total carried over from every earlier session in the process.
    @MainActor
    func testTouchEventCountResetsForFreshSession() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "14"
        app.launchEnvironment["WADDLE_DEBUG_INPUT_COUNTS"] = "1"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launch()

        let play = app.buttons["playFreedoom1"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()

        let fire = app.buttons["fireButton"]
        XCTAssertTrue(fire.waitForExistence(timeout: 20), "overlay never installed")

        // First session: feed the shim some real input so the counter is
        // provably nonzero when this session ends.
        fire.tap()
        app.buttons["useButton"].tap()

        let exitLabel = app.staticTexts["engineExitLabel"]
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90))
        XCTAssertEqual(exitLabel.label, "Engine exited: 0")

        let countLabel = app.staticTexts["touchEventCountLabel"]
        XCTAssertTrue(countLabel.waitForExistence(timeout: 5))
        let firstCount = Int(countLabel.label.replacingOccurrences(
            of: "touchEvents: ", with: "")) ?? 0
        XCTAssertGreaterThan(firstCount, 0,
            "first session saw no touch input; the zero-count assertion below would be vacuous")

        // Second session in the same process: start it and touch nothing.
        // Tapping the launcher tile is SwiftUI-side input; it never reaches
        // the shim's counter. The overlay appearing proves the session is
        // live (and that the HUD labels from session one are gone).
        play.tap()
        XCTAssertTrue(fire.waitForExistence(timeout: 20),
                      "overlay never installed for the second session")

        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90))
        XCTAssertEqual(exitLabel.label, "Engine exited: 0")
        XCTAssertFalse(fire.exists, "overlay not torn down after second session")

        XCTAssertTrue(countLabel.waitForExistence(timeout: 5))
        let secondCount = Int(countLabel.label.replacingOccurrences(
            of: "touchEvents: ", with: "")) ?? -1
        XCTAssertEqual(secondCount, 0,
            "second session performed zero touches but reports \(secondCount) touch events -- touch_event_count leaked across sessions")
    }

    /// Regression test: a fingertip that misses `weaponPrevButton` by a few
    /// points must not silently start a movement-stick track -- a mis-tap on
    /// "previous weapon" becoming a movement input.
    ///
    /// The hazard this was originally written for is now gone by
    /// construction, and that is worth stating rather than leaving the old
    /// rationale to rot. `weaponPrevButton` used to sit at
    /// `x: safeArea.left + 40`, squarely inside the movement stick's own
    /// capture column (`touchesBegan`'s `point.x < bounds.width * 0.4`), so
    /// a near-miss landed on bare overlay *inside the stick's own region*
    /// and only `nearButton`'s cushion kept it from steering.
    /// `TouchOverlayLayout` has since moved both weapon buttons into the
    /// right-hand cluster, well outside that column, so the near-miss half
    /// below now holds geometrically as well as by the cushion.
    ///
    /// It is kept because the property is still the one that matters and
    /// still regresses if the arrangement moves back; the control half below
    /// is what carries the discriminating power today. The surviving live
    /// hazard is the `modern` scheme, where the whole right region is a
    /// drag-to-turn surface and a near-miss beside FIRE can start a turn
    /// track -- that case is not covered here.
    ///
    /// Asserted on the app-owned `stickEngaged` marker rather than on any
    /// visible effect: a tap's stick track begins and ends in
    /// milliseconds, so a marker mirroring `stickTouch` live would read
    /// "off" either way. It latches instead, and the second half of this
    /// test taps clean overlay in the same column and requires it to
    /// appear -- otherwise a marker that never latched at all would make
    /// the near-miss assertion pass for entirely the wrong reason.
    @MainActor
    func testNearMissBesideWeaponPrevDoesNotStartStick() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "25"
        app.launchEnvironment["WADDLE_DEBUG_INPUT_COUNTS"] = "1"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launch()

        let play = app.buttons["playFreedoom1"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()

        let prev = app.buttons["weaponPrevButton"]
        XCTAssertTrue(prev.waitForExistence(timeout: 20), "overlay never installed")

        let stickEngaged = app.otherElements["stickEngaged"]
        XCTAssertFalse(stickEngaged.exists, "stick engaged before any overlay touch")

        // Straight below the button's center: 34pt clears the 48pt button's
        // own frame by ~10pt, and holds the same x -- still well inside the
        // stick's capture column, which is the whole point of the miss.
        prev.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: 34))
            .press(forDuration: 0.3)

        XCTAssertFalse(stickEngaged.waitForExistence(timeout: 3),
            "a near-miss beside weaponPrevButton started a movement-stick track")

        // Control: clean overlay in that same column must still engage the
        // stick, so the assertion above cannot pass by the marker simply
        // never latching, or by the fix having swallowed the stick whole.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.7))
            .press(forDuration: 0.3)
        XCTAssertTrue(stickEngaged.waitForExistence(timeout: 3),
            "stick never engaged on clean overlay -- the exclusion is too wide")

        let exitLabel = app.staticTexts["engineExitLabel"]
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90))
        XCTAssertEqual(exitLabel.label, "Engine exited: 0")
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

    /// `OverlayButton` is a square `UIView` drawn as a circle
    /// (`layer.cornerRadius = size / 2`), so UIKit's default rectangular
    /// hit-testing used to fire it from any of the four frame corners --
    /// points that are visually off the control. This performs exactly two
    /// taps on FIRE, one in a corner and one dead centre, and reads the
    /// post-session press counter: with a circular hit area only the centre
    /// tap counts, so the total is 1. Before the fix both taps landed and it
    /// was 2.
    ///
    /// The counter (OverlayButton.debugPressCount, surfaced by ContentView
    /// under WADDLE_DEBUG_INPUT_COUNTS) is read post-session for the same
    /// reason triggerResidueLabel is: the overlay is gone by the time the
    /// launcher is back on screen, so the value has to be cached rather than
    /// queried live. `OverlayButtonHitAreaTests` pins the same geometry
    /// directly in the unit suite.
    @MainActor
    func testCornerTapMissesCircularButton() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "14"
        app.launchEnvironment["WADDLE_DEBUG_INPUT_COUNTS"] = "1"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launch()

        let play = app.buttons["playFreedoom1"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()

        let fire = app.buttons["fireButton"]
        XCTAssertTrue(fire.waitForExistence(timeout: 20), "overlay never installed")

        // FIRE is 84pt. (0.08, 0.08) sits ~6.7pt inside the frame's top-left
        // corner and ~50pt from centre -- comfortably outside the 42pt drawn
        // circle, and comfortably inside the square frame the accessibility
        // element still reports, which is what makes this coordinate
        // addressable at all.
        fire.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.08)).tap()

        // Dead centre: unambiguously inside the circle.
        fire.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let exitLabel = app.staticTexts["engineExitLabel"]
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90))
        XCTAssertEqual(exitLabel.label, "Engine exited: 0")

        let pressLabel = app.staticTexts["buttonPressCountLabel"]
        XCTAssertTrue(pressLabel.waitForExistence(timeout: 5),
                      "no overlay-button press telemetry")
        let presses = Int(pressLabel.label.replacingOccurrences(
            of: "buttonPresses: ", with: "")) ?? -1
        XCTAssertEqual(presses, 1,
            "expected only the centre tap to press FIRE, got \(presses) presses "
            + "-- a corner tap outside the circular visual still reached the button")
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
