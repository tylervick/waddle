import XCTest

final class EngineSmokeTests: XCTestCase {

    /// Boots the engine, lets it run 10 s, auto-quits, verifies return to
    /// the launcher — then does it all AGAIN to prove teardown/reinit works.
    @MainActor
    func testEngineBootQuitRelaunchCycle() throws {
        let autoquitSeconds = 10.0

        let app = XCUIApplication()
        app.provideFreedoom()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launch()

        for cycle in 1...2 {
            let play = app.buttons["playFreedoom1"]
            XCTAssertTrue(play.waitForExistence(timeout: 10),
                          "cycle \(cycle): launcher not visible")
            // Stamp BEFORE the tap. XCUIElement.tap() returns only once the
            // app has gone idle again, and starting an engine session keeps the
            // main thread busy (SDL window, Metal pipeline), so on a slow
            // runner the return can trail the tap by seconds. A stamp taken
            // after it undercounts the session and fails the lower bound
            // below with exit 0 and a healthy engine (8.3 s for a 10 s window,
            // main run 37287887037). Every other suite stamps before the tap.
            let tappedAt = Date()
            play.tap()

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
                "it should run ~\(autoquitSeconds)s until WADDLE_AUTOQUIT_SECONDS fires")
        }
    }

    /// The first tile row stays playable in one tap while the welcome card
    /// is above it: a fresh, factory-state library, at the default text size
    /// and at the largest, where the card is tallest and the first row is a
    /// single full-width tile that reaches past the fold.
    ///
    /// Every other suite that plays Freedoom does it through
    /// `provideFreedoom()`, which imports it, and an imported file ends
    /// factory state (`LibraryService.isFactoryState()`), so none of them
    /// sees the welcome card any more (issue #504's review). Before the seam,
    /// those reset tests tapped `playFreedoom1` under the card on every run,
    /// and that is how this suite caught the card pushing the row out of
    /// reach (a30d17d8, `ShelfHeroLayout.welcomeCardShowsDescription`). This
    /// test keeps that check on purpose, so it runs on the bundle: no
    /// `provideFreedoom()`. #505, which stops bundling Freedoom, decides what a
    /// factory-state shelf holds and moves this test onto it.
    @MainActor
    func testFirstRowTileStartsASessionUnderTheWelcomeCard() throws {
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait
        for size in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = XCUIApplication()
            app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
            app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "3"
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", size]
            app.launch()

            let card = app.descendants(matching: .any).matching(identifier: "welcomeCard").firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 10),
                          "\(size): no welcome card on a reset store, so this test checks nothing")
            let play = app.buttons["playFreedoom1"]
            XCTAssertTrue(play.waitForExistence(timeout: 10), "\(size): no Freedoom Phase 1 tile")
            play.tap()

            let exitLabel = app.staticTexts["engineExitLabel"]
            XCTAssertTrue(exitLabel.waitForExistence(timeout: 90),
                          "\(size): tapping the first-row tile under the welcome card started no session")
            XCTAssertEqual(exitLabel.label, "Engine exited: 0", "\(size)")
            app.terminate()
        }
    }
}
