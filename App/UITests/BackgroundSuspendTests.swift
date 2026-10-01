import XCTest

/// Issue #111: backgrounding the app in the middle of a level must pause the
/// game and save it, so a session iOS reclaims while backgrounded loses
/// nothing and the shelf can offer to continue it.
///
/// The engine sees the transition as SDL's app events (i_video.c): on
/// resign-active it opens Woof's own menu, which is what freezes a
/// single-player world, and on background entry it writes `suspend.dsg`.
/// Both are counted at the site that does them and shown after the session
/// as `bgsave=<saves> bgpause=<pauses>` (`WoofIOS_DebugBackgroundState`,
/// under WADDLE_DEBUG_SESSION_START). The menu is read live from the debug
/// HUD's `menu=` field, the save from the shelf's own Continue hero, and the
/// resume from the HUD's `gs=`/`load=` fields after tapping that hero.
final class BackgroundSuspendTests: XCTestCase {

    @MainActor
    func testBackgroundingALiveLevelOpensTheMenuAndWritesASave() throws {
        let app = XCUIApplication()
        // A clean store: a save left by an earlier run would make the
        // Continue hero appear whether or not this session wrote one.
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "30"
        // Straight into E1M1: Woof autosaves only on level completion, so
        // the only save a warped session can leave behind is the one under
        // test.
        app.launchEnvironment["WADDLE_TEST_WARP"] = "1"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launchEnvironment["WADDLE_DEBUG_SESSION_START"] = "1"
        app.launchArguments += ["-debugHUD", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }
        let hero = app.descendants(matching: .any)["continueHero"]
        XCTAssertFalse(hero.exists, "the reset store must start without a Continue hero")

        let play = app.buttons["playFreedoom1"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()

        let hud = app.staticTexts["sessionDebugHUD"]
        XCTAssertTrue(hud.waitForExistence(timeout: 30), "debug HUD never appeared")
        let inLevel = waitForHUD(hud, timeout: 30) {
            $0["pad"]?.hasSuffix(" virtual") == true && $0["gs"] == "level" && $0["menu"] == "off"
        }
        XCTAssertEqual(inLevel["gs"], "level", "the warp should put the session in a level: \(lastSeenStrip)")
        XCTAssertEqual(inLevel["menu"], "off", "no menu should be up in the level: \(lastSeenStrip)")
        // Let the level run a while, so the save captures a leveltime a
        // fresh level could not have reached by the time the HUD first
        // reports it (the resume check below leans on that).
        Thread.sleep(forTimeInterval: 3)

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.activate()

        XCTAssertTrue(hud.waitForExistence(timeout: 15), "debug HUD gone after returning to the app")
        let afterReturn = waitForHUD(hud, timeout: 10) { $0["menu"] != nil && $0["menu"] != "off" }
        XCTAssertNotNil(afterReturn["menu"], "HUD lost its menu field: \(lastSeenStrip)")
        XCTAssertNotEqual(afterReturn["menu"], "off",
                          "backgrounding mid-level should leave the menu up on return: \(lastSeenStrip)")
        // For a human: the engine must be drawing again after the return (the
        // menu over the level), not showing its last frame or black. A device
        // run reads this off a screenshot; the assertions above cannot.
        Thread.sleep(forTimeInterval: 1.5)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "after-return-from-background"
        shot.lifetime = .keepAlways
        add(shot)

        let exitLabel = app.staticTexts["engineExitLabel"]
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90), "engine never returned to the launcher")
        XCTAssertEqual(exitLabel.label, "Engine exited: 0")

        XCTAssertTrue(hero.waitForExistence(timeout: 10),
                      "the shelf should offer Continue on the save the background transition wrote")
        let state = app.staticTexts["backgroundStateLabel"]
        XCTAssertTrue(state.waitForExistence(timeout: 5), "no background-state readout")
        let readout = fields(of: state.label)
        XCTAssertEqual(readout["bgsave"], "1", "one save expected: \(state.label)")
        XCTAssertEqual(readout["bgpause"], "1", "one pause expected: \(state.label)")
        let savedLevelTime = Int(readout["bglt"] ?? "") ?? -1
        XCTAssertGreaterThanOrEqual(savedLevelTime, 3 * 35,
                                    "the save should capture the level's ~3 s of play: \(state.label)")

        // Continue resumes that save through -loadgame 254. A command-line
        // load that fails falls back to the title (G_LoadAutoSaveErr), and
        // the warp seam stays out of a -loadgame session, so a session that
        // reports load=254 and gs=level did load it; a leveltime no lower
        // than the one saved says it is that level, not a fresh one.
        hero.tap()
        XCTAssertTrue(hud.waitForExistence(timeout: 30), "debug HUD never appeared for Continue")
        let resumed = waitForHUD(hud, timeout: 30) { $0["gs"] == "level" }
        XCTAssertEqual(resumed["load"], "254", "Continue should launch with -loadgame 254: \(lastSeenStrip)")
        XCTAssertEqual(resumed["gs"], "level", "the suspend save should load into its level: \(lastSeenStrip)")
        XCTAssertGreaterThanOrEqual(Int(resumed["lt"] ?? "") ?? -1, savedLevelTime,
                                    "the resumed level should continue from the saved leveltime: \(lastSeenStrip)")
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90), "resumed session never returned to the launcher")
        XCTAssertEqual(exitLabel.label, "Engine exited: 0")
    }

    /// The hook must do nothing when there is no level to keep: at the shelf
    /// (no engine at all) and on the title screen, whose demo is not the
    /// player's game.
    @MainActor
    func testBackgroundingOutsideALevelWritesNothing() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "12"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launchEnvironment["WADDLE_DEBUG_SESSION_START"] = "1"
        app.launchArguments += ["-debugHUD", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }
        let hero = app.descendants(matching: .any)["continueHero"]

        // No session: the transition has nothing to reach, and the shelf
        // comes back as it was.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 15),
                      "shelf did not come back after backgrounding with no session")
        XCTAssertFalse(hero.exists, "no session ran, so nothing can have been saved")

        // Title screen: the engine is live but there is no player's game.
        let play = app.buttons["playFreedoom1"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        let hud = app.staticTexts["sessionDebugHUD"]
        XCTAssertTrue(hud.waitForExistence(timeout: 30), "debug HUD never appeared")
        let booted = waitForHUD(hud, timeout: 30) {
            $0["pad"]?.hasSuffix(" virtual") == true && $0["gs"] == "title"
        }
        XCTAssertEqual(booted["pad"]?.hasSuffix(" virtual"), true, "engine never booted: \(lastSeenStrip)")
        XCTAssertEqual(booted["gs"], "title", "the session should be at the title: \(lastSeenStrip)")

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()

        let exitLabel = app.staticTexts["engineExitLabel"]
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90), "engine never returned to the launcher")
        XCTAssertEqual(exitLabel.label, "Engine exited: 0")
        let state = app.staticTexts["backgroundStateLabel"]
        XCTAssertTrue(state.waitForExistence(timeout: 5), "no background-state readout")
        XCTAssertEqual(state.label, "bgsave=0 bgpause=0 bglt=0")
        XCTAssertFalse(hero.exists, "a title-screen session must not leave a save behind")
    }

    // MARK: HUD reading (same strip DebugHUDInputTelemetryTests parses)

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

    /// The `gs=`, `bgsave=` and `pad=` segments' fields; a value runs until
    /// the next known key of its segment.
    private func fields(of label: String) -> [String: String] {
        let keysBySegment = ["gs": ["gs", "load", "lt"],
                             "bgsave": ["bgsave", "bgpause", "bglt"],
                             "pad": ["pad", "pads", "btn", "ly", "lypk", "vly", "ab", "mv", "menu"]]
        var result: [String: String] = [:]
        for segment in label.components(separatedBy: "\n").flatMap({ $0.components(separatedBy: " · ") }) {
            guard let keys = keysBySegment.first(where: { segment.hasPrefix("\($0.key)=") })?.value
            else { continue }
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
