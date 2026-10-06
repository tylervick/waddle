import XCTest
@testable import Waddle

/// The profiling seam (issue #246) turns three launch environment variables
/// into engine arguments. `Scripts/profile-session.sh` records the workload
/// it asked for next to every trace, so a request the app reads differently,
/// or half-honours, would attach a number to the wrong conditions.
final class ProfileHarnessTests: XCTestCase {
    func testNoVariablesIsNoRequest() {
        XCTAssertNil(ProfileHarness.request(environment: [:]))
    }

    func testGameAndDemoDefaultToRealTimePlayback() {
        let request = ProfileHarness.request(environment: [
            "WADDLE_PROFILE_GAME": "Freedoom Phase 2",
            "WADDLE_PROFILE_DEMO": "demo1",
        ])
        XCTAssertEqual(request, ProfileHarness.Request(
            gameName: "Freedoom Phase 2",
            engineArguments: ["-playdemo", "demo1", "-nogui"]))
    }

    func testTimedemoModeIsHonoured() {
        let request = ProfileHarness.request(environment: [
            "WADDLE_PROFILE_GAME": "Freedoom Phase 1",
            "WADDLE_PROFILE_DEMO": "DEMO3",
            "WADDLE_PROFILE_MODE": "timedemo",
        ])
        XCTAssertEqual(request?.engineArguments, ["-timedemo", "DEMO3", "-nogui"])
    }

    func testEitherRequiredVariableMissingIsNoRequest() {
        XCTAssertNil(ProfileHarness.request(environment: ["WADDLE_PROFILE_GAME": "Freedoom Phase 2"]))
        XCTAssertNil(ProfileHarness.request(environment: ["WADDLE_PROFILE_DEMO": "demo1"]))
    }

    /// An unknown mode must not fall back to the default: the script would
    /// record one workload while the app played another.
    func testUnknownModeIsNoRequest() {
        XCTAssertNil(ProfileHarness.request(environment: [
            "WADDLE_PROFILE_GAME": "Freedoom Phase 2",
            "WADDLE_PROFILE_DEMO": "demo1",
            "WADDLE_PROFILE_MODE": "fastdemo",
        ]))
    }

    /// The demo value reaches the engine's argv, so only a lump name passes:
    /// not a second flag, not a path, not more than eight characters.
    func testDemoMustBeALumpName() {
        for demo in ["", "-warp", "demo 1", "../x.lmp", "demo12345"] {
            XCTAssertNil(ProfileHarness.request(environment: [
                "WADDLE_PROFILE_GAME": "Freedoom Phase 2",
                "WADDLE_PROFILE_DEMO": demo,
            ]), "accepted \(demo.debugDescription)")
        }
    }
}
