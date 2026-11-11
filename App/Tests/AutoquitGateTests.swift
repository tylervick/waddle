import XCTest
@testable import Waddle

/// Issue #380: a UI test's autoquit ended the session under the test on a
/// slow runner. `AutoquitGate` is the rule for when a session armed with
/// `WADDLE_AUTOQUIT_SECONDS` is asked to quit; these cases pin both forms of
/// it. That the release actually crosses from the test runner into the app
/// is the UI suite's to show (`DebugHUDInputTelemetryTests` and the others
/// that call `releaseAutoquit()`).
final class AutoquitGateTests: XCTestCase {

    // MARK: Held (WADDLE_AUTOQUIT_HOLD)

    /// The failure the issue records: the budget runs out while the test is
    /// still in the middle of its steps. The session must stay up.
    func testAHeldAutoquitDoesNotQuitWhenTheBudgetRunsOutMidStep() {
        var gate = AutoquitGate(held: true)
        XCTAssertFalse(gate.deadlineDidPass(), "the session was ended under a test still at work")
    }

    /// The slow runner: the budget is long gone when the test finishes, and
    /// the session ends right then.
    func testAHeldAutoquitQuitsOnReleaseOnceTheBudgetHasRunOut() {
        var gate = AutoquitGate(held: true)
        _ = gate.deadlineDidPass()
        XCTAssertTrue(gate.testDidRelease())
    }

    /// The fast machine: the test finishes inside the budget, and the session
    /// still runs for all of it, as it did before the hold existed. Tests
    /// assert on that length (`MenuStateAcrossSessionsTests`).
    func testAHeldAutoquitReleasedEarlyStillRunsItsWholeBudget() {
        var gate = AutoquitGate(held: true)
        XCTAssertFalse(gate.testDidRelease(), "a release must not cut the budget short")
        XCTAssertTrue(gate.deadlineDidPass())
    }

    // MARK: Not held

    /// Without the hold the budget alone decides, exactly as before:
    /// `EngineSmokeTests` measures it.
    func testAPlainAutoquitQuitsWhenTheBudgetRunsOut() {
        var gate = AutoquitGate(held: false)
        XCTAssertTrue(gate.deadlineDidPass())
    }

    /// A release reaching a launch that did not ask for the hold ends
    /// nothing, before the budget or after it.
    func testAReleaseDoesNothingToAPlainAutoquit() {
        var gate = AutoquitGate(held: false)
        XCTAssertFalse(gate.testDidRelease())
        XCTAssertTrue(gate.deadlineDidPass())
        XCTAssertFalse(gate.testDidRelease())
    }
}
