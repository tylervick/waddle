import XCTest

/// Investigation harness for cross-session menu state.
///
/// `WoofIOS_Run` runs `D_DoomMain` more than once per process, but the menu
/// tables in `Engine/woof/src/mn_menu.c` are static C globals that `M_Init`
/// mutates in place per session (`MainDef.numitems--`, `MainDef.y += 8`,
/// `MainMenu[readthis] = MainMenu[quitdoom]`, `EpiDef.numitems--`) and never
/// restores. Every commercial session (Freedoom Phase 2) therefore shortens
/// and shifts the main menu for every later session, of any game.
///
/// This test captures the main menu (and, for Phase 1, the episode menu) as
/// screenshot attachments across four in-process sessions so the drift can be
/// seen: Phase 1 fresh, Phase 2 twice, Phase 1 again.
final class MenuStateAcrossSessionsTests: XCTestCase {

    private let autoquitSeconds = 16.0

    @MainActor
    func testMenuScreensAcrossPhase1Phase2Phase2Phase1() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }

        let phase1 = app.buttons["playFreedoom1"]
        let phase2 = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'game-' AND identifier CONTAINS 'Freedoom Phase 2'"))
            .firstMatch

        capture(app, tile: phase1, name: "1-phase1-fresh", openEpisodes: true)
        capture(app, tile: phase2, name: "2-phase2-first", openEpisodes: false)
        capture(app, tile: phase2, name: "3-phase2-second", openEpisodes: false)
        capture(app, tile: phase1, name: "4-phase1-after-two-phase2", openEpisodes: true)
    }

    /// Companion probe for what the Revyl device run showed: with the touch
    /// overlay NOT forced (the shipping state when a keyboard or gamepad is
    /// reported), the only way into the in-game menu is SDL's own
    /// touch-to-mouse path, and any mouse button on the title/demo screen
    /// opens the menu. On the device run that worked in session 1 and did
    /// nothing in session 2. This does the same two sessions in the
    /// simulator and attaches what the tap produced each time.
    @MainActor
    func testSdlTouchOpensMenuOnSecondSession() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }

        let phase2 = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'game-' AND identifier CONTAINS 'Freedoom Phase 2'"))
            .firstMatch
        let exitLabel = app.staticTexts["engineExitLabel"]

        for session in 1...2 {
            let name = "sdl-touch-session\(session)"
            XCTAssertTrue(phase2.waitForExistence(timeout: 30), "\(name): tile missing")
            let start = Date()
            phase2.tap()
            XCTAssertTrue(exitLabel.waitForNonExistence(timeout: 15),
                          "\(name): previous exit label never cleared")
            Thread.sleep(forTimeInterval: 7)
            attach(name: "\(name)-before-tap")
            // Middle of the screen: inside the engine's viewport in portrait,
            // away from every overlay control position.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
            attach(name: "\(name)-after-tap")
            XCTAssertTrue(exitLabel.waitForExistence(timeout: 90),
                          "\(name): engine never returned to the launcher")
            XCTAssertEqual(exitLabel.label, "Engine exited: 0", "\(name): exit code")
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertGreaterThanOrEqual(elapsed, autoquitSeconds - 1.0,
                "\(name): session died before its autoquit window (\(elapsed)s)")
        }
    }

    /// Plays a tile for one autoquit window, opens the in-game menu via the
    /// overlay's menu button, and attaches what the engine drew.
    private func capture(_ app: XCUIApplication, tile: XCUIElement, name: String,
                         openEpisodes: Bool,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "\(name): tile missing",
                      file: file, line: line)
        let exitLabel = app.staticTexts["engineExitLabel"]
        let start = Date()
        tile.tap()
        XCTAssertTrue(exitLabel.waitForNonExistence(timeout: 15),
                      "\(name): previous exit label never cleared", file: file, line: line)

        let menuButton = app.buttons["menuButton"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 30),
                      "\(name): overlay menu button missing", file: file, line: line)
        // Let the engine reach the title screen before opening the menu.
        Thread.sleep(forTimeInterval: 6)
        menuButton.tap()
        Thread.sleep(forTimeInterval: 1.5)
        attach(name: "\(name)-main-menu")

        if openEpisodes {
            // The cursor rests on New Game; USE is the menu confirm button.
            app.buttons["useButton"].tap()
            Thread.sleep(forTimeInterval: 1.5)
            attach(name: "\(name)-episodes")
        }

        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90),
                      "\(name): engine never returned to the launcher", file: file, line: line)
        XCTAssertEqual(exitLabel.label, "Engine exited: 0",
                       "\(name): engine exit code was not 0", file: file, line: line)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, autoquitSeconds - 1.0,
            "\(name): session died before its autoquit window (\(elapsed)s)",
            file: file, line: line)
    }

    private func attach(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
