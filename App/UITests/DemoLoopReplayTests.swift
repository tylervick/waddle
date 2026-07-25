import XCTest

/// Regression test for the crash-on-replay bug in the vendored Woof! engine's
/// `D_SetupDemoLoop` (`Engine/woof/src/d_demoloop.c`).
///
/// The file-scope globals `demoloop` / `demoloop_count` were never reset
/// between the in-process play sessions that `WoofIOS_Run` runs — upstream Woof
/// runs `D_DoomMain` once per process, so the statics were assumed to die with
/// the process. On session 2+, `demoloop` still points at a previous session's
/// STATIC default array (assigned in `D_GetDefaultDemoLoop`), and
/// `D_CheckPrimaryLumps` calls `array_free(demoloop)` when the current IWAD is
/// missing one of the default demoloop's primary lumps — an `m_array` free of
/// memory located *before* a static C array → `EXC_CRASH (SIGABRT)` /
/// `POINTER_BEING_FREED_WAS_NOT_ALLOCATED`.
///
/// Reproduction (matches the confirmed TestFlight crash — a user who loaded
/// Doom II):
///  1. Play the bundled **Freedoom Phase 1** loadout. It is a retail
///     (Ultimate-Doom) IWAD, so `D_GetDefaultDemoLoop` selects
///     `demoloop_retail` with `demoloop_count == 7` (its 7th entry is DEMO4,
///     which Freedoom 1 has, so nothing is trimmed). Session 1 never runs
///     `D_CheckPrimaryLumps` — `demoloop` is still NULL when it's checked,
///     because there's no `DEMOLOOP` lump to parse — so it exits cleanly.
///  2. Play a **DOOM2** loadout. DOOM2 is commercial and, crucially, has NO
///     DEMO4 lump. On this second session the stale `demoloop` pointer and
///     `demoloop_count == 7` survive, `if (demoloop)` is now true,
///     `D_CheckPrimaryLumps` walks all 7 retail entries against DOOM2's lumps,
///     finds DEMO4 missing at index 6, and `array_free()`s the static
///     `demoloop_retail` → abort.
///
/// Both sessions must exit cleanly ("Engine exited: 0"). Before the fix,
/// session 2 aborts the whole app process and the exit label never appears.
///
/// DOOM2.WAD is copyrighted and not in CI, so this test **skips** cleanly when
/// it hasn't been provisioned into the simulator's Documents (see
/// `Scripts/provision-test-wads.sh`).
final class DemoLoopReplayTests: XCTestCase {

    private let autoquitSeconds = 8.0

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Play"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }
        return app
    }

    /// Polls the Library tab for `name` (async loose-file adoption may take a
    /// few seconds after launch). Returns whether it ever showed up — the
    /// caller decides skip vs. fail, since the required IWAD is copyrighted.
    private func wadAppears(app: XCUIApplication, name: String,
                            timeout: TimeInterval = 30) -> Bool {
        let libraryTab = app.tabBars.buttons["Library"]
        let playTab = app.tabBars.buttons["Play"]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            libraryTab.tap()
            if app.staticTexts[name].waitForExistence(timeout: 2) {
                playTab.tap()
                return true
            }
            playTab.tap()
        } while Date() < deadline
        return false
    }

    /// Plays a loadout by its tile id and asserts a full-length clean session.
    private func playAndAssertCleanSession(app: XCUIApplication, tileID: String,
                                           label: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        let tile = app.buttons[tileID]
        XCTAssertTrue(tile.waitForExistence(timeout: 10),
                      "\(label): play tile '\(tileID)' missing", file: file, line: line)

        let exitLabel = app.staticTexts["engineExitLabel"]
        let start = Date()
        tile.tap()
        // The app clears the exit label when the new session starts, and the
        // engine window takes over. A previous session's label (identical text)
        // must vanish first, or we'd match it before session 2 even boots.
        // Session 1 has no prior label, so this returns immediately.
        XCTAssertTrue(exitLabel.waitForNonExistence(timeout: 15),
                      "\(label): previous exit label never cleared; session likely failed to start",
                      file: file, line: line)
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90),
                      "\(label): engine never returned to the launcher (crash?)",
                      file: file, line: line)
        XCTAssertEqual(exitLabel.label, "Engine exited: 0",
                       "\(label): engine exit code was not 0", file: file, line: line)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, autoquitSeconds - 1.0,
            "\(label): session died before its autoquit window (\(elapsed)s)",
            file: file, line: line)
    }

    @MainActor
    func testDoom2AfterFreedoomDoesNotCrashOnReplay() throws {
        let app = launchApp()

        // Gate: DOOM2 must be provisioned (copyrighted; not in CI).
        guard wadAppears(app: app, name: "DOOM2") else {
            throw XCTSkip("DOOM2.WAD not provisioned into the simulator — see " +
                          "Scripts/provision-test-wads.sh. Skipping.")
        }

        // Session 1: bundled Freedoom Phase 1 (retail) — leaves the stale
        // demoloop_retail static + demoloop_count == 7 the bug feeds on.
        playAndAssertCleanSession(app: app, tileID: "playFreedoom1",
                                  label: "session 1 (Freedoom Phase 1)")

        // Create the DOOM2 loadout (commercial IWAD, no DEMO4 lump).
        let doom2Tile = app.buttons["loadout-DoomII"]
        if !doom2Tile.exists {
            app.buttons["newLoadoutButton"].tap()
            let nameField = app.textFields["loadoutNameField"]
            XCTAssertTrue(nameField.waitForExistence(timeout: 5))
            nameField.tap()
            nameField.typeText("DoomII")
            app.buttons["iwadPicker"].tap()
            app.buttons["DOOM2"].tap()
            app.buttons["saveLoadoutButton"].tap()
            XCTAssertTrue(doom2Tile.waitForExistence(timeout: 5),
                          "DOOM2 loadout tile missing after save")
        }

        // Session 2: DOOM2. Pre-fix, D_CheckPrimaryLumps array_free()s the
        // stale static demoloop_retail -> SIGABRT; the app process dies and
        // the exit label never appears.
        playAndAssertCleanSession(app: app, tileID: "loadout-DoomII",
                                  label: "session 2 (DOOM2 replay)")
    }
}
