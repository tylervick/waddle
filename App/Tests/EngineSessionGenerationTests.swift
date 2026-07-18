import XCTest
@testable import BoomBox

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
}
