import XCTest
@testable import BoomBox

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
}
