import XCTest

/// Verifies the four-finger-tap soft keyboard summons only during live
/// gameplay and dismisses. Correctness is asserted on the app-owned
/// `softKeyboardActive` marker, not on `app.keyboards` -- the simulator's
/// connected hardware keyboard can suppress the system keyboard's own
/// rendering, so the marker is the only reliable signal here. The dismiss
/// half of the round trip does tap the real system keyboard's Return key
/// (see the comment at that call site for why), but only as a stimulus;
/// the marker's disappearance is still what's asserted. Actual cheat
/// activation is device-verified (see the design spec).
final class SoftKeyboardTests: XCTestCase {

    @MainActor
    func testFourFingerTapSummonsAndDismissesInGame() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "25"
        // The Simulator reports a phantom controller/keyboard, which would
        // otherwise hide the overlay (see OverlayPresenter.applyPolicy).
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        // playFreedoom1 alone lands on the title screen, not live gameplay
        // -- fireButton existing only proves the overlay installed, not
        // that WoofIOS_GetTextInputContext() reports GAMEPLAY yet (see
        // TouchControlsTests.testFireReleaseClearsTriggerResidue for the
        // same precedent: title-screen FIRE hits menu-select behavior, not
        // the real gameplay path). Force straight into a level so the tap
        // deterministically lands during GAMEPLAY.
        app.launchEnvironment["WADDLE_TEST_WARP"] = "1"
        app.launch()

        let play = app.buttons["playFreedoom1"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()

        XCTAssertTrue(app.buttons["fireButton"].waitForExistence(timeout: 20),
                      "overlay never installed")

        let marker = app.otherElements["softKeyboardActive"]
        XCTAssertFalse(marker.exists, "keyboard active before any tap")

        // Four-finger tap at the center of the screen (empty overlay area).
        app.tap(withNumberOfTaps: 1, numberOfTouches: 4)
        XCTAssertTrue(marker.waitForExistence(timeout: 5),
                      "four-finger tap did not summon the keyboard in-game")

        // The real system keyboard is genuinely on screen now (present()
        // calls becomeFirstResponder()), which -- confirmed by inspecting
        // the failing run's accessibility snapshot -- adds several more
        // full-screen "Other" elements to the hierarchy (the keyboard's own
        // subtree, plus the launcher's SwiftUI view, which stays resident
        // full-frame underneath the SDL window the whole session). With
        // enough overlapping full-frame "Other" elements on screen,
        // XCUITest's automatic 4-point placement for a second
        // app.tap(withNumberOfTaps:numberOfTouches:) can no longer find a
        // valid non-overlapping arrangement and fails outright ("Unable to
        // compute coordinates for gesture") regardless of which element
        // (app / window / touchOverlay) the tap is scoped to -- verified
        // all three scopes fail identically. This is a synthesis-tooling
        // limitation, not a wiring bug: the same handleSummonTap code path
        // handles both summon and dismiss (gated only on
        // `keyboard.isVisible`), and the summon half above already proves
        // four simultaneous touches are detected and routed correctly.
        // Exercise the dismiss half through the real keyboard's Return key
        // instead -- still real production code (TouchKeyboard.onReturn ->
        // dismissKeyboard()), just a reliable stimulus.
        let returnKey = app.keyboards.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'return'")).firstMatch
        XCTAssertTrue(returnKey.waitForExistence(timeout: 5),
                      "system keyboard never appeared to dismiss via Return")
        returnKey.tap()
        // waitForExistence returns false once the marker leaves the tree.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: marker)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testFourFingerTapIgnoredWhileMenuOpen() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "25"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        // See the sibling test above: force real gameplay first so "open
        // the menu" genuinely leaves a GAMEPLAY context, matching this
        // test's docstring, rather than just dismissing a title screen.
        app.launchEnvironment["WADDLE_TEST_WARP"] = "1"
        app.launch()

        app.buttons["playFreedoom1"].tap()
        XCTAssertTrue(app.buttons["menuButton"].waitForExistence(timeout: 20))

        // Open the in-game menu -> context leaves GAMEPLAY.
        app.buttons["menuButton"].tap()

        let marker = app.otherElements["softKeyboardActive"]
        app.tap(withNumberOfTaps: 1, numberOfTouches: 4)
        XCTAssertFalse(marker.waitForExistence(timeout: 3),
                       "keyboard wrongly summoned while a menu was open")
    }
}
