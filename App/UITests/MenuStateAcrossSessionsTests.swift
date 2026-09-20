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
    @discardableResult
    private func capture(_ app: XCUIApplication, tile: XCUIElement, name: String,
                         openEpisodes: Bool,
                         file: StaticString = #filePath, line: UInt = #line) -> String? {
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

        // Debug-only telemetry: the menu tables as the *next* session will
        // inherit them (WADDLE_DEBUG_MENU_GEOMETRY, see ContentView).
        let geometry = app.staticTexts["menuGeometryLabel"]
        return geometry.waitForExistence(timeout: 5) ? geometry.label : nil
    }

    /// The regression test for issue #253: every session must start from the
    /// pristine menu tables, whatever ran before it in the same process.
    ///
    /// Reads the tables through the debug label after each session; the
    /// statics outlive the session, so what the label shows is exactly what
    /// the next session inherits. Before the fix, each Phase 2 session takes
    /// one entry off the main menu and one episode off Phase 1, so the label
    /// after session 4 reads main=4 / epi=2 instead of main=6 / epi=4.
    @MainActor
    func testMenuTablesAreRestoredForEachSession() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launchEnvironment["WADDLE_DEBUG_MENU_GEOMETRY"] = "1"
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }

        let phase1 = app.buttons["playFreedoom1"]
        let phase2 = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'game-' AND identifier CONTAINS 'Freedoom Phase 2'"))
            .firstMatch

        let afterPhase1Fresh = capture(app, tile: phase1, name: "g1-phase1-fresh", openEpisodes: false)
        let afterPhase2First = capture(app, tile: phase2, name: "g2-phase2-first", openEpisodes: false)
        let afterPhase2Second = capture(app, tile: phase2, name: "g3-phase2-second", openEpisodes: false)
        let afterPhase1Again = capture(app, tile: phase1, name: "g4-phase1-after-two-phase2", openEpisodes: false)

        XCTAssertNotNil(afterPhase1Fresh, "menuGeometryLabel never appeared after session 1")

        // Absolute values for a retail IWAD on a fresh process: six main-menu
        // entries at y=64, four episodes (mn_menu.c MainDef / EpiDef).
        XCTAssertEqual(afterPhase1Fresh, "main=6@64 epi=4@63",
                       "fresh Phase 1 tables are not the pristine ones")
        // A commercial session edits the tables for itself: five entries,
        // eight pixels lower, one episode fewer. The second commercial session
        // must see exactly the same edits, not the edits applied twice.
        XCTAssertEqual(afterPhase2Second, afterPhase2First,
                       "second Phase 2 session inherited the first one's menu edits")
        // And a retail session after any number of commercial ones must get
        // the pristine tables back.
        XCTAssertEqual(afterPhase1Again, afterPhase1Fresh,
                       "Phase 1 after two Phase 2 sessions inherited their menu edits")
    }

    private func attach(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
