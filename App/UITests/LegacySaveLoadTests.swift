import XCTest

/// Issue #339: a save written by Waddle 1.3 (Woof master `798acebd`, binary
/// keyframes stamped `"Woof 16.0.0"`) must still load on the 16.0.0 engine,
/// which writes JSON under the same stamp and whose upstream legacy table
/// stops at `"Woof 15.0.0"`.
///
/// `Fixtures/suspend-waddle-1.3.dsg` is such a save, made by 1.3 itself (see
/// the README beside it). Each case hands it to the app through
/// `WADDLE_TEST_SUSPEND_SAVE`, which installs it as Freedoom Phase 1's
/// suspend save and marks the game played, so the shelf's Continue hero
/// resumes exactly that file with `-loadgame 254`.
///
/// Both cases read the session's debug HUD (`-debugHUD YES`): `load=` is the
/// `-loadgame` argument the engine saw, `gs=` its game state, `lt=` leveltime.
final class LegacySaveLoadTests: XCTestCase {

    /// The fixture's own leveltime, read from its header: after the 24-byte
    /// description, 16-byte stamp, 5 single bytes (demo_version 221 = MBF21,
    /// compatibility, skill, episode, map), 8-byte checksum, the NUL-terminated
    /// WAD list, 32 `playeringame` bytes (MIN_MAXPLAYERS), 1 `idmusnum`, the
    /// MBF21 options block (21 + 25 comp bytes) and the snapshot's 5
    /// custom-skill bytes comes `leveltime` as a little-endian int32: 129 tics,
    /// the ~3.7 s BackgroundSuspendTests had played before backgrounding.
    private let fixtureLevelTime = 129

    /// A 1.3 save resumes through Continue into its level, at or past its
    /// saved leveltime. On the unpatched engine this session sits on the title
    /// screen under "Different Savegame Version!!!" instead (gs=title).
    @MainActor
    func testASaveWrittenByWaddle13LoadsThroughContinue() throws {
        // Autoquit after the 30 s HUD wait below, so a session that never
        // reaches the level is still on screen to report its state (gs=title)
        // rather than gone, which would read as a missing HUD.
        let app = try launch(withSuspendSave: fixtureBytes(), autoquitSeconds: 40)

        let hud = app.staticTexts["sessionDebugHUD"]
        XCTAssertTrue(hud.waitForExistence(timeout: 30), "debug HUD never appeared for Continue")
        let resumed = waitForHUD(hud, timeout: 30) { $0["gs"] == "level" }
        XCTAssertEqual(resumed["load"], "254", "Continue should launch with -loadgame 254: \(lastSeenStrip)")
        XCTAssertEqual(resumed["gs"], "level",
                       "the 1.3 save should load into its level, not stall on the title: \(lastSeenStrip)")
        XCTAssertGreaterThanOrEqual(Int(resumed["lt"] ?? "") ?? -1, fixtureLevelTime,
                                    "the level should continue from the saved leveltime: \(lastSeenStrip)")

        let exitLabel = app.staticTexts["engineExitLabel"]
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90), "resumed session never returned to the launcher")
        XCTAssertEqual(exitLabel.label, "Engine exited: 0")
        XCTAssertEqual(engineErrorAlerts(in: app).count, 0, "no engine-error alert expected after a clean resume")
    }

    /// The same file with a stamp the engine has never seen. Before #339 a
    /// forced load of such a file parsed every field one byte off and ended
    /// the session in `I_Error` ("The -beta option is required..."), which the
    /// app shows as an alert titled with the engine version. Now the load is
    /// refused: the session falls back to the title screen and exits cleanly.
    @MainActor
    func testAnUnknownStampIsRefusedWithoutAnEngineError() throws {
        var bytes = try fixtureBytes()
        let stamp = Array("Woof 99.0.0".utf8) + [UInt8](repeating: 0, count: 5)
        XCTAssertEqual(stamp.count, 16)
        bytes.replaceSubrange(24..<40, with: stamp)
        let app = try launch(withSuspendSave: bytes, autoquitSeconds: 12)

        let hud = app.staticTexts["sessionDebugHUD"]
        XCTAssertTrue(hud.waitForExistence(timeout: 30), "debug HUD never appeared for Continue")
        let seen = waitForHUD(hud, timeout: 15) { $0["gs"] == "level" }
        XCTAssertEqual(seen["load"], "254", "Continue should still launch with -loadgame 254: \(lastSeenStrip)")
        XCTAssertNotEqual(seen["gs"], "level", "an unknown stamp must not be parsed into a level: \(lastSeenStrip)")

        let exitLabel = app.staticTexts["engineExitLabel"]
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90),
                      "the session should autoquit from the title screen; an engine error would block that")
        XCTAssertEqual(exitLabel.label, "Engine exited: 0", "a refused load must not be an engine error")
        XCTAssertEqual(engineErrorAlerts(in: app).count, 0,
                       "the engine-error alert is the failure this case exists to catch")
    }

    // MARK: Plumbing

    private func fixtureBytes() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "suspend-waddle-1.3",
                                                            withExtension: "dsg"),
                                "suspend-waddle-1.3.dsg is missing from the test bundle")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 171481, "fixture size changed; regenerate per Fixtures/README.md")
        XCTAssertEqual(String(decoding: data[24..<35], as: UTF8.self), "Woof 16.0.0",
                       "the fixture should carry the binary 'Woof 16.0.0' stamp")
        return data
    }

    /// Launches with `bytes` installed as Freedoom Phase 1's suspend save and
    /// taps the Continue hero it produces. The bytes travel raw-deflate
    /// compressed and base64 encoded (171 KB -> ~53 KB), the same way
    /// `WADDLE_TEST_ZIP_<n>` carries a WAD.
    @MainActor
    private func launch(withSuspendSave bytes: Data, autoquitSeconds: Int) throws -> XCUIApplication {
        let compressed = try (bytes as NSData).compressed(using: .zlib) as Data
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launchEnvironment["WADDLE_TEST_SUSPEND_SAVE"] = compressed.base64EncodedString()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = String(autoquitSeconds)
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launchArguments += ["-debugHUD", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90), "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }

        let hero = app.descendants(matching: .any)["continueHero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 15),
                      "the seeded suspend save should put a Continue hero on the shelf")
        hero.tap()
        return app
    }

    private func engineErrorAlerts(in app: XCUIApplication) -> XCUIElementQuery {
        app.alerts.matching(NSPredicate(format: "label BEGINSWITH 'Woof'"))
    }

    // MARK: HUD reading (same strip BackgroundSuspendTests parses)

    private var lastSeenStrip = ""

    private func waitForHUD(_ hud: XCUIElement, timeout: TimeInterval,
                            until condition: ([String: String]) -> Bool) -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        var parsed = fields(of: lastStrip(hud))
        while !condition(parsed) && Date() < deadline && hud.exists {
            Thread.sleep(forTimeInterval: 0.25)
            parsed = fields(of: lastStrip(hud))
        }
        return parsed
    }

    private func lastStrip(_ hud: XCUIElement) -> String {
        if hud.exists { lastSeenStrip = hud.label }
        return lastSeenStrip
    }

    /// The `gs=` segment's fields; a value runs until the next known key.
    private func fields(of label: String) -> [String: String] {
        let keys = ["gs", "load", "lt"]
        var result: [String: String] = [:]
        for segment in label.components(separatedBy: "\n").flatMap({ $0.components(separatedBy: " · ") })
        where segment.hasPrefix("gs=") {
            var rest = segment
            for (i, key) in keys.enumerated() {
                guard let range = rest.range(of: "\(key)=") else { continue }
                let after = rest[range.upperBound...]
                let end = keys.dropFirst(i + 1).compactMap { after.range(of: " \($0)=")?.lowerBound }.min()
                    ?? after.endIndex
                result[key] = String(after[..<end])
                rest = String(after[end...])
            }
        }
        return result
    }
}
