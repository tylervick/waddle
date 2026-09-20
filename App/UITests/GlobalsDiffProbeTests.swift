import XCTest

/// Drives the engine's writable-globals diff (`WADDLE_DEBUG_GLOBALS_DIFF`,
/// see `WoofIOS_DebugGlobalsCheckpoint` in `Engine/woof/src/woof_ios.c`).
///
/// Plays a sequence of games in ONE app process, letting each session end
/// through the autoquit seam. At the start of every session's game loop the
/// engine snapshots its image's writable data sections and, from the second
/// session on, prints one `GLOBALDIFF` line per byte range that changed
/// since the previous checkpoint. Those lines land in the session log
/// (`Diagnostics/session-*.log` in the app container) and in the xcresult's
/// captured stdout; `Scripts/globals-diff.py` turns them into symbol names.
///
/// The sequence comes from the test runner's environment, so the same probe
/// serves "same game twice" (state that leaks between sessions of one game)
/// and "game A then game B" (state that depends on the previous game):
///
///     TEST_RUNNER_WADDLE_GLOBALS_DIFF_GAMES="Freedoom Phase 2,Freedoom Phase 2" \
///       xcodebuild ... -only-testing:WaddleUITests/GlobalsDiffProbeTests test
///
/// Names are shelf tile names; "Freedoom Phase 1" and "Freedoom Phase 2" are
/// always present, imported IWADs (DOOM2, TNT, ...) use their catalog title.
/// Default: Freedoom Phase 2 twice, the pair issue #253 was found with.
final class GlobalsDiffProbeTests: XCTestCase {

    private let autoquitSeconds = 12.0

    @MainActor
    func testPlaysTheSequenceAndEverySessionExitsCleanly() throws {
        let sequence = (ProcessInfo.processInfo.environment["WADDLE_GLOBALS_DIFF_GAMES"]
            ?? "Freedoom Phase 2,Freedoom Phase 2")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertGreaterThanOrEqual(sequence.count, 2,
            "a diff needs at least two sessions; got \(sequence)")

        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launchEnvironment["WADDLE_DEBUG_GLOBALS_DIFF"] = "1"
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }

        let exitLabel = app.staticTexts["engineExitLabel"]
        for (index, name) in sequence.enumerated() {
            let tile = name == "Freedoom Phase 1"
                ? app.buttons["playFreedoom1"]
                : app.buttons["game-\(name)"]
            XCTAssertTrue(tile.waitForExistence(timeout: 30),
                          "session \(index + 1): no tile named '\(name)' on the shelf")
            let start = Date()
            tile.tap()
            XCTAssertTrue(exitLabel.waitForNonExistence(timeout: 15),
                          "session \(index + 1) (\(name)): previous exit label never cleared")
            XCTAssertTrue(exitLabel.waitForExistence(timeout: 90),
                          "session \(index + 1) (\(name)): engine never returned to the launcher")
            XCTAssertEqual(exitLabel.label, "Engine exited: 0",
                           "session \(index + 1) (\(name)): engine exit code was not 0")
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertGreaterThanOrEqual(elapsed, autoquitSeconds - 1.0,
                "session \(index + 1) (\(name)): died before its autoquit window (\(elapsed)s)")
        }
    }
}
