import XCTest
@testable import Waddle

final class PhysicalInputPolicyTests: XCTestCase {
    func testNoPhysicalInputShowsOverlay() {
        let policy = PhysicalInputPolicy(controllerConnected: false,
                                         hardwareKeyboardConnected: false)
        XCTAssertTrue(policy.overlayShouldShow)
    }

    func testControllerHidesOverlay() {
        let policy = PhysicalInputPolicy(controllerConnected: true,
                                         hardwareKeyboardConnected: false)
        XCTAssertFalse(policy.overlayShouldShow)
    }

    func testKeyboardHidesOverlay() {
        let policy = PhysicalInputPolicy(controllerConnected: false,
                                         hardwareKeyboardConnected: true)
        XCTAssertFalse(policy.overlayShouldShow)
    }

    // MARK: Auto-use (issue #114)

    /// Auto-use is a touch affordance: a usable line ahead of a forward-moving
    /// player presses USE for them, because their only USE is a button. A
    /// player driving with a physical controller or a hardware keyboard has a
    /// USE under a finger and must not have doors opened for them, so the
    /// policy that hides the overlay for physical input is the policy that
    /// turns auto-use off. One decision, not two that can drift.
    func testAutoUseFollowsTheOverlay() {
        XCTAssertTrue(PhysicalInputPolicy(controllerConnected: false, hardwareKeyboardConnected: false).autoUseEnabled)
        XCTAssertFalse(PhysicalInputPolicy(controllerConnected: true, hardwareKeyboardConnected: false).autoUseEnabled)
        XCTAssertFalse(PhysicalInputPolicy(controllerConnected: false, hardwareKeyboardConnected: true).autoUseEnabled)
        XCTAssertFalse(PhysicalInputPolicy(controllerConnected: true, hardwareKeyboardConnected: true).autoUseEnabled)
    }
}
