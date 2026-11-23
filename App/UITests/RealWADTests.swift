import XCTest

/// Requires Scripts/provision-test-wads.sh to have been run against the
/// booted simulator AFTER the app was installed. Each test creates a game
/// through the real UI and plays it with autoquit, asserting a full-length
/// session (helpers in XCTestCase+GameSessions.swift). Local-only: the WADs
/// are non-redistributable, so ui-tests.yml skips this class. The negative
/// case, which needs no real WAD, is UnrecognizedIWADTests, and runs in CI.
final class RealWADTests: XCTestCase {

    private func launchApp() -> XCUIApplication {
        launchForGameSessions()
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
}
