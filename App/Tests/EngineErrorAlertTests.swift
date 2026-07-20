import XCTest
@testable import WADdle

final class EngineErrorAlertTests: XCTestCase {
    func testCleanExitProducesNoAlert() {
        XCTAssertNil(EngineErrorAlert.from(exitCode: 0, engineMessage: nil))
    }

    func testErrorExitCarriesEngineText() {
        let alert = EngineErrorAlert.from(exitCode: -1,
                                          engineMessage: "Unknown or invalid IWAD file.")
        XCTAssertEqual(alert?.engineMessage, "Unknown or invalid IWAD file.")
        XCTAssertNotNil(alert?.hint)   // IWAD problems get a hint
    }

    func testWrongIWADHint() {
        let alert = EngineErrorAlert.from(exitCode: -1,
                                          engineMessage: "W_GetNumForName: TEXTURE2 not found")
        XCTAssertEqual(alert?.hint,
            "This usually means the WAD needs a different base game (IWAD). Try pairing it with Doom II / Freedoom Phase 2.")
    }

    func testUnknownErrorHasNoHintButStillAlerts() {
        let alert = EngineErrorAlert.from(exitCode: -1, engineMessage: "Z_Malloc: failure")
        XCTAssertNil(alert?.hint)
        XCTAssertEqual(alert?.title, "Couldn't run this loadout")
    }

    func testMissingMessageGetsGenericText() {
        let alert = EngineErrorAlert.from(exitCode: -101, engineMessage: nil)
        XCTAssertEqual(alert?.engineMessage, "The engine reported no details (exit code -101).")
    }

    func testGenericNotFoundMessageHasNoHint() {
        // "not found" alone is too broad a marker (e.g. R_InitSprites can
        // report a missing sprite lump for reasons that have nothing to do
        // with IWAD pairing); W_GetNumForName is the real wrong-IWAD
        // signature and already covers the pairing case below.
        let alert = EngineErrorAlert.from(exitCode: -1,
                                          engineMessage: "R_InitSprites: sprite TROO not found")
        XCTAssertNil(alert?.hint)
    }

    func testFailedToLoadWrongIWADHint() {
        let alert = EngineErrorAlert.from(exitCode: -1,
                                          engineMessage: "Failed to load /path/badiwad.wad")
        XCTAssertNotNil(alert?.hint)   // D_AddFile's "Failed to load" is a wrong-IWAD marker too
    }

    func testReentrancyExitMapsToAccurateAlert() {
        let alert = EngineErrorAlert.from(exitCode: -102,
                                          engineMessage: "Another session is already running.")
        XCTAssertEqual(alert?.engineMessage, "Another session is already running.")
        XCTAssertNil(alert?.hint)   // not a WAD-pairing problem
        XCTAssertEqual(alert?.title, "Couldn't run this loadout")
    }
}
