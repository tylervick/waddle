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
}
