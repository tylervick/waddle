import XCTest

/// Negative case for a game whose IWAD the engine cannot load: the session
/// must fail fast with a nonzero exit, the engine's error text must reach
/// the launcher's alert, and the app must survive to the shelf.
///
/// It used to live in `RealWADTests`, which CI skips as a class because its
/// other cases need non-redistributable WADs, and it depended on
/// Scripts/provision-test-wads.sh writing its fixture by hand. So it ran
/// nowhere, and broke unnoticed when the engine's error box began holding
/// the session open until tapped (issue #513). It now brings its own
/// fixture through the WADDLE_TEST_LOOSE_FILE seam and runs on every
/// `push: main` UI test run.
///
/// The fixture is a synthetic 12-byte "IWAD": header "IWAD", numLumps 0,
/// dirOffset 12. It passes the app's own WADParser (magic plus an in-bounds,
/// empty directory) and is imported as an IWAD, so it becomes a base game.
/// The engine cannot use it: W_AddPath rejects the zero-lump file and
/// D_AddFile calls I_Error("Failed to load <path>") before the title screen
/// renders (observed in the surfaced alert text; CheckIWAD's "Unknown or
/// invalid IWAD file." is never reached), a real, argv-only engine failure
/// that unwinds back to WoofIOS_Run's caller instead of ending the process
/// (Engine/woof/src/i_exit.c and woof_ios.c).
///
/// History: this first paired a real MAPxx megawad (sunlust.wad) with a
/// Doom-1-format IWAD (Freedoom Phase 1) as a "wrong pairing". That does not
/// fail: Woof never auto-warps into a level without -warp (which the app's
/// LaunchArguments never passes), so the mismatched session idles on the
/// title screen for its autoquit window and exits 0; mismatched texture
/// patches are substituted, not fatal; and DEHACKED's hard-fail path is dead
/// code upstream. An unrecognized IWAD is the reliable way to make the engine
/// actually error out.
final class UnrecognizedIWADTests: XCTestCase {

    static let badIWAD = Data([0x49, 0x57, 0x41, 0x44,   // "IWAD"
                               0x00, 0x00, 0x00, 0x00,   // numLumps 0
                               0x0c, 0x00, 0x00, 0x00])  // dirOffset 12

    @MainActor
    func testUnrecognizedIWADFailsSoft() {
        // Start from a clean store so the game is built through the UI every
        // run, and leave one behind: without the reset, the bad base game
        // would sit on the shelf and in Files for every later test.
        addTeardownBlock {
            let cleanup = XCUIApplication()
            cleanup.launchEnvironment["WADDLE_RESET_STORE"] = "1"
            cleanup.launch()
            cleanup.terminate()
        }
        let app = launchForGameSessions(environment: [
            "WADDLE_RESET_STORE": "1",
            "WADDLE_TEST_LOOSE_FILE_NAME": "badiwad.wad",
            "WADDLE_TEST_LOOSE_FILE": Self.badIWAD.base64EncodedString(),
        ])
        runGame(app: app, name: "BadIWAD", iwad: "badiwad", pwad: nil,
                iwadFilename: "badiwad.wad", expectFullSession: false)
    }
}
