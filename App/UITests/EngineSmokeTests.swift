import XCTest

final class EngineSmokeTests: XCTestCase {

    /// Boots the engine, lets it run 10 s, auto-quits, verifies return to
    /// the launcher — then does it all AGAIN to prove teardown/reinit works.
    @MainActor
    func testEngineBootQuitRelaunchCycle() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BOOMBOX_AUTOQUIT_SECONDS"] = "10"
        app.launch()

        for cycle in 1...2 {
            let play = app.buttons["playFreedoom1"]
            XCTAssertTrue(play.waitForExistence(timeout: 10),
                          "cycle \(cycle): launcher not visible")
            play.tap()

            let exitLabel = app.staticTexts["engineExitLabel"]
            XCTAssertTrue(exitLabel.waitForExistence(timeout: 90),
                          "cycle \(cycle): engine did not return to launcher")
            XCTAssertEqual(exitLabel.label, "Engine exited: 0",
                           "cycle \(cycle): engine exit code was not 0")
        }
    }
}
