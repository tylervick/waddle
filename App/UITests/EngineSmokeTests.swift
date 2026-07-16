import XCTest

final class EngineSmokeTests: XCTestCase {

    /// Boots the engine, lets it run 10 s, auto-quits, verifies return to
    /// the launcher — then does it all AGAIN to prove teardown/reinit works.
    @MainActor
    func testEngineBootQuitRelaunchCycle() throws {
        let autoquitSeconds = 10.0

        let app = XCUIApplication()
        app.launchEnvironment["BOOMBOX_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launch()

        for cycle in 1...2 {
            let play = app.buttons["playFreedoom1"]
            XCTAssertTrue(play.waitForExistence(timeout: 10),
                          "cycle \(cycle): launcher not visible")
            play.tap()
            let tappedAt = Date()

            // Any exit label from the previous cycle must first vanish (the
            // app clears it when a session starts, and the engine's window
            // takes over the screen). Without this, cycle 2 could match the
            // stale cycle-1 label — same text — before the session even boots.
            // Cycle 1 has no label, so this returns immediately.
            let exitLabel = app.staticTexts["engineExitLabel"]
            XCTAssertTrue(exitLabel.waitForNonExistence(timeout: 15),
                          "cycle \(cycle): previous exit label never cleared; engine session likely failed to start")

            XCTAssertTrue(exitLabel.waitForExistence(timeout: 90),
                          "cycle \(cycle): engine did not return to launcher")
            XCTAssertEqual(exitLabel.label, "Engine exited: 0",
                           "cycle \(cycle): engine exit code was not 0")

            // A session that ends before its own autoquit fires is a dead
            // session, even with exit code 0 (e.g. a stray quit event ending
            // the engine during startup). Require the session to have lived
            // through (almost) the whole autoquit window.
            let elapsed = Date().timeIntervalSince(tappedAt)
            XCTAssertGreaterThanOrEqual(
                elapsed, autoquitSeconds - 1.0,
                "cycle \(cycle): engine exited after only \(elapsed)s — " +
                "it should run ~\(autoquitSeconds)s until BOOMBOX_AUTOQUIT_SECONDS fires")
        }
    }
}
