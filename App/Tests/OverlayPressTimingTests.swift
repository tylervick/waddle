import XCTest
@testable import Waddle

/// A tap on an overlay button becomes a virtual-gamepad button state that
/// SDL samples only when the engine pumps events, once per tic at worst
/// (35 Hz, about 29 ms apart). A down and an up that both land between two
/// pumps leave the state unchanged and the press is never seen. Measured on
/// Revyl's farm device: the overlay counted the USE tap's two touch events
/// while the engine's button-event count did not move. The model holds the
/// release back until the press has lasted long enough to straddle a pump.
final class OverlayPressTimingTests: XCTestCase {

    func testReleaseInsideTheMinimumHoldIsDelayedByTheRemainder() {
        var timing = OverlayPressTiming(minimumHold: 0.070)
        timing.pressed(at: 10.000)
        XCTAssertEqual(timing.released(at: 10.005), 0.065, accuracy: 0.0005)
    }

    func testReleaseAfterTheMinimumHoldIsImmediate() {
        var timing = OverlayPressTiming(minimumHold: 0.070)
        timing.pressed(at: 10.000)
        XCTAssertEqual(timing.released(at: 10.100), 0)
    }

    func testReleaseWithoutAPressIsImmediate() {
        var timing = OverlayPressTiming(minimumHold: 0.070)
        XCTAssertEqual(timing.released(at: 5), 0)
    }

    func testMinimumHoldCoversTwoEnginePumpsAtThirtyFiveHertz() {
        // Two pumps, so that one pump observing the down is guaranteed even
        // when the press starts just after a pump.
        XCTAssertGreaterThanOrEqual(OverlayPressTiming.engineSafe.minimumHold, 2.0 / 35.0)
    }
}
