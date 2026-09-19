import XCTest

/// Requires Scripts/provision-test-wads.sh to have been run against the
/// booted simulator AFTER the app was installed. Each test creates a game
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
        // Task 7), not synchronously in WaddleApp.init — so the launcher UI
        // shows up immediately and does NOT wait on hashing/copying the
        // provisioned WADs (including the 293 MB Eviternity II). Adoption
        // finishing is awaited separately, per-game, in
        // waitForWADAvailable below.
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90),
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

    /// Waits for `filename` to show up as a row in Settings → Files.
    ///
    /// Async adoption (Plan 3 Task 7) means a provisioned loose WAD may not
    /// be registered into the library for a few seconds after launch (the
    /// 293 MB Eviternity II in particular needs to be hashed + copied off
    /// Main first). The Add… picker on the game page is NOT a fix point to
    /// poll directly: its candidate list is a plain computed property, not a
    /// reactive SwiftData query, so it only reflects the library's current
    /// contents at the moment that view's body is (re-)evaluated — simply
    /// leaving the picker sheet open longer never picks up a WAD that gets
    /// registered after the sheet was presented. The Files screen re-fetches
    /// on every `onAppear`, so poll there instead — then open a *fresh* Add…
    /// picker only once the target WAD is confirmed present, so its first
    /// render already reflects it.
    ///
    /// Each row is a single combined accessibility element identified by
    /// `fileRow-<on-disk filename>` (not a standalone staticText keyed by
    /// display name), and its underlying XCUIElementType varies (cell vs.
    /// other) depending on how the List renders sectioned rows — so this
    /// matches by identifier across `.any` element type rather than assuming
    /// a specific type or querying `staticTexts`.
    private func waitForWADAvailable(app: XCUIApplication, filename: String,
                                     timeout: TimeInterval = 90,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            openFiles(app, file: file, line: line)
            let row = app.descendants(matching: .any)
                .matching(identifier: "fileRow-\(filename)").firstMatch
            let found = row.waitForExistence(timeout: 2)
            closeSettings(app, file: file, line: line)
            if found { return }
        } while Date() < deadline
        XCTFail("WAD '\(filename)' never appeared in Files (async adoption stalled?)",
                file: file, line: line)
    }

    /// Clears any existing text in `field` (e.g. the game page's
    /// auto-generated name) before typing `text`.
    /// Creates (if needed) and plays a game; asserts session length.
    ///
    /// `iwad`/`pwad` are WAD *display names* (they address
    /// `game-<displayName>`/`addFile-<displayName>` below);
    /// `iwadFilename`/`pwadFilename` are the corresponding on-disk filenames
    /// the fixtures are provisioned under (see
    /// Scripts/provision-test-wads.sh) and are what the Files screen's rows
    /// are keyed by — pass them whenever the two differ (i.e. whenever a
    /// `waitForWADAvailable` wait is needed).
    private func runGame(app: XCUIApplication, name: String, iwad: String,
                         pwad: String?, pwadFilename: String? = nil,
                         iwadFilename: String? = nil, expectFullSession: Bool,
                         file: StaticString = #filePath, line: UInt = #line) {
        let tile = app.buttons["game-\(name)"]
        if !tile.exists {
            if let pwad { waitForWADAvailable(app: app, filename: pwadFilename ?? pwad, file: file, line: line) }
            if !iwad.hasPrefix("Freedoom") { waitForWADAvailable(app: app, filename: iwadFilename ?? iwad, file: file, line: line) }
            // A modded game is a duplicate of its base game with files added
            // (spec §3.2): Duplicate the base, open the copy, rename, Add….
            let baseTile = iwad == "Freedoom Phase 1" ? "playFreedoom1" : "game-\(iwad)"
            openGamePage(app, tile: baseTile, file: file, line: line)
            app.buttons["duplicateButton"].tap()
            openGamePage(app, tile: "game-\(iwad) copy", file: file, line: line)
            app.buttons["gameNameButton"].tap()
            let field = renameField(in: app)
            XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
            clearAndType(field, name)
            app.buttons["Save"].tap()
            if let pwad {
                app.buttons["addFileButton"].tap()
                let row = app.buttons["addFile-\(pwad)"]
                XCTAssertTrue(row.waitForExistence(timeout: 5), "\(pwad) missing from the Add picker", file: file, line: line)
                row.tap()
            }
            returnToShelf(app, file: file, line: line)
            XCTAssertTrue(tile.waitForExistence(timeout: 5), "game tile missing after setup", file: file, line: line)
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
            let alert = app.alerts["Couldn't run this game"]
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
            // App survived the engine error — launcher still interactive. The
            // shelf's Add button stands in for the departed tab bar here: it
            // is the one piece of shelf chrome that is always present.
            XCTAssertTrue(app.buttons["importButton"].isHittable, file: file, line: line)
        }
    }

    @MainActor
    func testVanillaScytheOnFreedoom2() {
        let app = launchApp()
        runGame(app: app, name: "Scythe", iwad: "Freedoom Phase 2",
                   pwad: "SCYTHE", pwadFilename: "SCYTHE.WAD", expectFullSession: true)
    }

    @MainActor
    func testBoomSunlustOnFreedoom2() {
        let app = launchApp()
        runGame(app: app, name: "Sunlust", iwad: "Freedoom Phase 2",
                   pwad: "sunlust", pwadFilename: "sunlust.wad", expectFullSession: true)
    }

    @MainActor
    func testMBF21EviternityIIOnFreedoom2() {
        let app = launchApp()
        runGame(app: app, name: "Eviternity II", iwad: "Freedoom Phase 2",
                   pwad: "Eviternity II", pwadFilename: "Eviternity II.wad", expectFullSession: true)
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
    /// (which this app's LaunchArguments never passes), so a mismatched
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
        runGame(app: app, name: "BadIWAD", iwad: "badiwad", pwad: nil,
                   iwadFilename: "badiwad.wad", expectFullSession: false)
    }
}
