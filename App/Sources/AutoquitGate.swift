#if DEBUG
/// When a UI test's autoquit may end the session it was armed for.
///
/// `WADDLE_AUTOQUIT_SECONDS` is a wall-clock budget: the session is asked to
/// quit that many seconds after it starts. A test that taps and drags inside
/// the session is guessing how long its own steps take, and on a slow CI
/// runner a tap that takes under a second locally takes nine (issue #380):
/// the budget runs out mid-step, the session ends under the test, and the
/// next tap finds the shelf where the overlay was.
///
/// A launch that also sets `WADDLE_AUTOQUIT_HOLD` gets a held autoquit. The
/// budget still runs, and the session still lasts at least that long, but it
/// is not asked to quit until the test has also said its steps are done
/// (`EngineSession.autoquitReleaseNotification`). On a machine fast enough to
/// finish the steps inside the budget nothing changes, to the second; on a
/// slow one the session waits for the test.
///
/// Debug builds only, like the seam it belongs to.
struct AutoquitGate: Equatable {
    /// Whether the autoquit waits for the test (`WADDLE_AUTOQUIT_HOLD`).
    let held: Bool
    private(set) var deadlinePassed = false
    private(set) var released = false

    init(held: Bool) { self.held = held }

    /// The budget has run out. True if the session should be asked to quit now.
    mutating func deadlineDidPass() -> Bool {
        deadlinePassed = true
        return !held || released
    }

    /// The test has finished its steps. True if the session should be asked
    /// to quit now. On an autoquit that is not held this changes nothing: the
    /// budget alone decides.
    mutating func testDidRelease() -> Bool {
        released = true
        return held && deadlinePassed
    }
}
#endif
