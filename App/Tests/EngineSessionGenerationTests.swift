import XCTest
@testable import WADdle

/// The autoquit timer must only fire for the session it was created for
/// (ledgered Plan-1 finding: a stale timer could quit the NEXT session).
@MainActor
final class EngineSessionGenerationTests: XCTestCase {
    func testGenerationIncrementsPerPlayCall() {
        let before = EngineSession.sessionGeneration
        // play() would block on a real engine; we only test the guard's
        // bookkeeping helper here.
        EngineSession.beginSessionForTesting()
        XCTAssertEqual(EngineSession.sessionGeneration, before + 1)
        EngineSession.beginSessionForTesting()
        XCTAssertEqual(EngineSession.sessionGeneration, before + 2)
    }

    func testStaleGenerationIsDetected() {
        EngineSession.beginSessionForTesting()
        let captured = EngineSession.sessionGeneration
        XCTAssertTrue(EngineSession.isCurrentGeneration(captured))
        EngineSession.beginSessionForTesting()
        XCTAssertFalse(EngineSession.isCurrentGeneration(captured))
    }

    /// The -102 reentrancy guard must leave an accurate lastErrorMessage,
    /// never a stale one from an earlier failed session (fix-round finding:
    /// the guard previously returned without touching it, so a -102 alert
    /// could show the previous session's error text).
    func testReentrantPlaySetsAccurateErrorMessage() {
        EngineSession.setRunningForTesting(true)
        defer { EngineSession.setRunningForTesting(false) }
        let code = EngineSession.play(arguments: ["woof"])
        XCTAssertEqual(code, -102)
        XCTAssertEqual(EngineSession.lastErrorMessage,
                       "Another session is already running.")
    }
}
