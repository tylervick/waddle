import XCTest

/// Requires Scripts/provision-test-wads.sh to have been run against the
/// booted simulator AFTER the app was installed. Each test creates a loadout
/// through the real UI, plays it with autoquit, and asserts a full-length
/// session (or, for the negative case, a fast engine-error exit that the app
/// survives).
final class RealWADTests: XCTestCase {

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "10"
        app.launch()
        // Loose-file adoption (ImportService.adoptLooseFiles) now runs
        // asynchronously off a `.task` on ContentView's first frame (Plan 3
        // Task 7), not synchronously in WADdleApp.init — so the launcher UI
        // shows up immediately and does NOT wait on hashing/copying the
        // provisioned WADs (including the 293 MB Eviternity II). Adoption
        // finishing is awaited separately, per-loadout, in
        // waitForWADAvailable below.
        XCTAssertTrue(app.tabBars.buttons["Play"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        // Dismiss the loose-file adoption alert if it fired this launch.
        // NOTE: launch-time adoption is currently silent (no alert; the
        // "Import complete" alert only fires from LibraryView's manual
        // import flow) so this is expected to be a no-op today. Kept as a
        // guard in case that changes.
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }
        return app
    }

    /// Waits for `name` to show up in the Library tab's WAD list.
    ///
    /// Async adoption (Plan 3 Task 7) means a provisioned loose WAD may not
    /// be registered into the library for a few seconds after launch (the
    /// 293 MB Eviternity II in particular needs to be hashed + copied off
    /// Main first). LoadoutEditorView's "Add PWAD" menu is NOT a fix point
    /// to poll directly: its `pwads` list is a plain computed property, not
    /// a reactive SwiftData query, so it only reflects the library's
    /// current contents at the moment that view's body is (re-)evaluated —
    /// simply leaving the "New Loadout" sheet open longer never picks up a
    /// WAD that gets registered after the sheet was presented. LibraryView
    /// re-fetches on every `onAppear`, and switching tabs re-fires it, so
    /// poll there instead — then open a *fresh* "New Loadout" sheet only
    /// once the target WAD is confirmed present, so its first render
    /// already reflects it.
    private func waitForWADAvailable(app: XCUIApplication, name: String,
                                     timeout: TimeInterval = 90,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let libraryTab = app.tabBars.buttons["Library"]
        let playTab = app.tabBars.buttons["Play"]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            libraryTab.tap()
            if app.staticTexts[name].waitForExistence(timeout: 2) {
                playTab.tap()
                return
            }
            playTab.tap()
        } while Date() < deadline
        XCTFail("WAD '\(name)' never appeared in the Library tab (async adoption stalled?)",
                file: file, line: line)
    }

    /// Creates (if needed) and plays a loadout; asserts session length.
    private func runLoadout(app: XCUIApplication, name: String, iwad: String,
                            pwad: String?, expectFullSession: Bool,
                            file: StaticString = #filePath, line: UInt = #line) {
        let tile = app.buttons["loadout-\(name)"]
        if !tile.exists {
            if let pwad {
                waitForWADAvailable(app: app, name: pwad, file: file, line: line)
            }
            if !iwad.hasPrefix("Freedoom") {
                // Bundled Freedoom IWADs are registered synchronously at
                // launch and always available; anything else (e.g. the
                // provisioned "badiwad" fixture) is a loose file subject to
                // the same async adoption race as PWADs above — wait for it
                // too, or the picker tap below can race the hash/copy.
                waitForWADAvailable(app: app, name: iwad, file: file, line: line)
            }
            app.buttons["newLoadoutButton"].tap()
            let nameField = app.textFields["loadoutNameField"]
            XCTAssertTrue(nameField.waitForExistence(timeout: 5), file: file, line: line)
            nameField.tap()
            nameField.typeText(name)
            app.buttons["iwadPicker"].tap()
            app.buttons[iwad].tap()
            if let pwad {
                // Tab-bar buttons have no accessibility ids on iOS 26; this
                // isn't a tab-bar button though — it's the "Add PWAD" Menu
                // inside the loadout editor form, which does carry its own
                // id (and, unlike the bare "Add PWAD" text row, has a
                // full-row hit area).
                app.buttons["addPWADMenu"].tap()
                app.buttons["addPWADButton-\(pwad)"].tap()
            }
            app.buttons["saveLoadoutButton"].tap()
            XCTAssertTrue(tile.waitForExistence(timeout: 5),
                          "loadout tile missing after save", file: file, line: line)
        }

        let exitLabel = app.staticTexts["engineExitLabel"]
        let start = Date()
        tile.tap()
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90),
                      "engine never returned", file: file, line: line)
        let elapsed = Date().timeIntervalSince(start)
        if expectFullSession {
            XCTAssertEqual(exitLabel.label, "Engine exited: 0", file: file, line: line)
            XCTAssertGreaterThanOrEqual(elapsed, 9.0,
                "session died before its autoquit window", file: file, line: line)
        } else {
            XCTAssertNotEqual(exitLabel.label, "Engine exited: 0",
                "bad WAD selection unexpectedly booted", file: file, line: line)
            // The engine's own error text must surface as a launcher alert
            // (Plan 4 Task 1). Dismiss it before the interactivity check
            // below — a presented alert intercepts hits on everything else.
            let alert = app.alerts["Couldn't run this loadout"]
            XCTAssertTrue(alert.waitForExistence(timeout: 5),
                          "engine error alert not shown", file: file, line: line)
            // Not just the (hardcoded) title: the body must carry the
            // engine's own errmsg text, proving the errmsg → shim →
            // EngineSession → alert pipeline end to end. The zero-lump
            // fixture actually dies in D_AddFile's I_Error("Failed to load
            // %s", file) — W_AddPath rejects it before CheckIWAD's "Unknown
            // or invalid IWAD file." is ever reached (verified via the
            // alert hierarchy in a debug run; older comments claiming
            // CheckIWAD fires were source-reading, not observation). Match
            // stable substrings only — the full path varies per container.
            XCTAssertTrue(alert.staticTexts.matching(NSPredicate(
                format: "label CONTAINS 'Failed to load' AND label CONTAINS 'badiwad.wad'"))
                .firstMatch.exists,
                "alert body missing the engine's error text", file: file, line: line)
            alert.buttons["OK"].tap()
            // App survived the engine error — launcher still interactive.
            // Tab-bar buttons carry no accessibility id on iOS 26 (the
            // native tab bar is reconstructed by the system and doesn't
            // inherit identifiers set on tabItem content); address the
            // button by its label instead.
            XCTAssertTrue(app.tabBars.buttons["Play"].isHittable, file: file, line: line)
        }
    }

    @MainActor
    func testVanillaScytheOnFreedoom2() {
        let app = launchApp()
        runLoadout(app: app, name: "Scythe", iwad: "Freedoom Phase 2",
                   pwad: "SCYTHE", expectFullSession: true)
    }

    @MainActor
    func testBoomSunlustOnFreedoom2() {
        let app = launchApp()
        runLoadout(app: app, name: "Sunlust", iwad: "Freedoom Phase 2",
                   pwad: "sunlust", expectFullSession: true)
    }

    @MainActor
    func testMBF21EviternityIIOnFreedoom2() {
        let app = launchApp()
        runLoadout(app: app, name: "Eviternity II", iwad: "Freedoom Phase 2",
                   pwad: "Eviternity II", expectFullSession: true)
    }

    /// Negative: an unrecognized/invalid IWAD (zero Doom-recognizable
    /// lumps, so Woof's own gamemode detection can't identify it). The
    /// engine must fail fast with a nonzero exit, and the app must survive
    /// to the launcher.
    ///
    /// This originally paired a real MAPxx megawad (sunlust.wad) with a
    /// Doom-1-format IWAD (Freedoom Phase 1) to exercise a "wrong
    /// pairing". Verified against the engine source
    /// (Engine/woof/src/d_main.c CheckIWAD/IdentifyVersion, r_data.c
    /// R_InitTextures) and empirically on-device that this does NOT fail:
    /// Woof never auto-warps into a level without an explicit -warp flag
    /// (which this app's LoadoutArguments never passes), so a mismatched
    /// session just idles on the title screen for its whole autoquit
    /// window and exits 0. Missing/mismatched texture patches are also
    /// handled non-fatally (a dummy patch is substituted), and DEHACKED's
    /// hard-fail path is dead code upstream. Scripts/provision-test-wads.sh
    /// instead drops a synthetic 12-byte "IWAD"-header file with zero
    /// lumps (badiwad.wad); in practice W_AddPath() rejects the zero-lump
    /// file and D_AddFile() calls I_Error("Failed to load <path>") before
    /// the title screen renders (observed in the surfaced alert text —
    /// CheckIWAD's "Unknown or invalid IWAD file." path is never reached)
    /// — a real, argv-only engine failure that (per
    /// Engine/woof/src/i_exit.c + woof_ios.c) unwinds cleanly back to
    /// WoofIOS_Run's caller instead of terminating the process.
    @MainActor
    func testUnrecognizedIWADFailsSoft() {
        let app = launchApp()
        runLoadout(app: app, name: "BadIWAD", iwad: "badiwad",
                   pwad: nil, expectFullSession: false)
    }
}
