import XCTest

/// Requires Scripts/provision-test-wads.sh to have been run against the
/// booted simulator AFTER the app was installed. Each test creates a loadout
/// through the real UI, plays it with autoquit, and asserts a full-length
/// session (or, for the negative case, a fast engine-error exit that the app
/// survives).
final class RealWADTests: XCTestCase {

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BOOMBOX_AUTOQUIT_SECONDS"] = "10"
        app.launch()
        // Loose-file adoption (BoomBoxApp.init -> ImportService.adoptLooseFiles)
        // runs synchronously before the first frame renders. Whichever test
        // happens to run first after provisioning finds all three provisioned
        // WADs (including the 293 MB Eviternity II) still sitting in
        // Documents and pays for hashing + copying all of them before the
        // launcher UI exists at all. Wait generously for a landmark element
        // instead of assuming the UI is ready immediately after launch()
        // returns.
        XCTAssertTrue(app.tabBars.buttons["Play"].waitForExistence(timeout: 90),
                      "launcher UI never appeared (loose-file adoption stalled?)")
        // Dismiss the loose-file adoption alert if it fired this launch.
        // NOTE: launch-time adoption is currently silent (no alert; the
        // "Import complete" alert only fires from LibraryView's manual
        // import flow) so this is expected to be a no-op today. Kept as a
        // guard in case that changes.
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }
        return app
    }

    /// Creates (if needed) and plays a loadout; asserts session length.
    private func runLoadout(app: XCUIApplication, name: String, iwad: String,
                            pwad: String?, expectFullSession: Bool,
                            file: StaticString = #filePath, line: UInt = #line) {
        let tile = app.buttons["loadout-\(name)"]
        if !tile.exists {
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
    /// lumps (badiwad.wad); CheckIWAD() can't find a gamemode signature in
    /// it and calls I_Error("Unknown or invalid IWAD file.") before the
    /// title screen renders — a real, argv-only engine failure that (per
    /// Engine/woof/src/i_exit.c + woof_ios.c) unwinds cleanly back to
    /// WoofIOS_Run's caller instead of terminating the process.
    @MainActor
    func testWrongIWADPairingFailsSoft() {
        let app = launchApp()
        runLoadout(app: app, name: "BadIWAD", iwad: "badiwad",
                   pwad: nil, expectFullSession: false)
    }
}
