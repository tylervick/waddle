import XCTest

/// Two TestFlight reports from August 2026 (digest issue #299): "Quit Game
/// doesn't work, it just opens a different screen", and "no exit option after
/// Continuing the second time". The first is the quit prompt ("press y or n")
/// that USE could not confirm while the virtual pad was not the one the
/// engine read (fixed by #259: `MN_Responder` turns MENU_ENTER into 'y'); the
/// second is the commercial-mode `MainDef.numitems--` that accumulated across
/// in-process sessions and dropped Quit Game from the second one (fixed by
/// #255). This drives the path a touch player takes, twice in one launch:
/// open the menu with ≡, walk the cursor to Quit Game with the stick, confirm
/// with USE, confirm the prompt with USE, and expect the session to end on
/// its own well before the autoquit would.
final class QuitGameTests: XCTestCase {
    /// Long enough that an ended session is attributable to the quit, not
    /// to the autoquit safety net.
    private let autoquitSeconds = 120.0

    @MainActor
    func testQuitGameFromTheOverlayEndsTheSessionTwiceInARow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launchEnvironment["WADDLE_TEST_WARP"] = "1"
        app.launchArguments += ["-debugHUD", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }

        // Freedoom Phase 2 identifies as commercial, the mode whose menu
        // table lost Quit Game on the second session.
        let phase2 = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'game-' AND identifier CONTAINS 'Freedoom Phase 2'"))
            .firstMatch
        for session in 1...2 {
            quitThroughTheMenu(app, tile: phase2, name: "session \(session)")
        }
    }

    /// Commercial main menu after M_Init: New Game, Options, Load Game,
    /// Save Game, Quit Game (Read This! is removed). Quit Game is item 4.
    private let quitItem = 4

    @MainActor
    private func quitThroughTheMenu(_ app: XCUIApplication, tile: XCUIElement, name: String) {
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "\(name): tile missing")
        let exitLabel = app.staticTexts["engineExitLabel"]
        tile.tap()
        XCTAssertTrue(exitLabel.waitForNonExistence(timeout: 15), "\(name): previous exit label never cleared")
        let hud = app.staticTexts["sessionDebugHUD"]
        XCTAssertTrue(hud.waitForExistence(timeout: 30), "\(name): debug HUD never appeared")
        let booted = waitForHUD(hud, timeout: 30) { $0["pad"]?.hasSuffix(" virtual") == true }
        XCTAssertEqual(booted["pad"]?.hasSuffix(" virtual"), true,
                       "\(name): engine should have the overlay's virtual pad open: \(lastSeenStrip)")
        XCTAssertTrue(app.buttons["menuButton"].waitForExistence(timeout: 10), "\(name): no menu button")

        app.buttons["menuButton"].tap()
        let menuOpen = waitForHUD(hud, timeout: 10) { $0["menu"] == "0" }
        XCTAssertEqual(menuOpen["menu"], "0", "\(name): menu cursor should be on item 0: \(lastSeenStrip)")

        // Walk to Quit Game one short stick flick at a time, reading the
        // cursor back after each. A flick can auto-repeat and overshoot
        // (DebugHUDInputTelemetryTests), so this loops until the cursor is
        // on Quit rather than counting flicks; the menu wraps, so overshoot
        // is not fatal.
        var cursor = menuOpen["menu"] ?? ""
        var flicks = 0
        while cursor != "\(quitItem)" && flicks < 16 {
            let stickStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.72))
            let stickEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.86))
            stickStart.press(forDuration: 0.05, thenDragTo: stickEnd, withVelocity: .fast,
                             thenHoldForDuration: 0.05)
            flicks += 1
            let before = cursor
            cursor = waitForHUD(hud, timeout: 3) { $0["menu"] != before }["menu"] ?? cursor
        }
        XCTAssertEqual(cursor, "\(quitItem)",
                       "\(name): could not reach Quit Game after \(flicks) flicks: \(lastSeenStrip)")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "\(name)-cursor-on-quit"
        shot.lifetime = .keepAlways
        add(shot)

        // USE selects Quit Game; the engine shows its "press y or n" prompt,
        // and a second USE is the 'y' (MN_Responder maps MENU_ENTER to it).
        // With quit_prompt off the first USE already quits, so the second is
        // sent only if the session is still up.
        let tappedQuit = Date()
        app.buttons["useButton"].tap()
        if !exitLabel.waitForExistence(timeout: 6) {
            let prompt = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            prompt.name = "\(name)-quit-prompt"
            prompt.lifetime = .keepAlways
            add(prompt)
            app.buttons["useButton"].tap()
        }
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 20),
                      "\(name): the session did not end after confirming Quit Game: \(lastSeenStrip)")
        XCTAssertEqual(exitLabel.label, "Engine exited: 0", "\(name): quit should exit 0")
        let elapsed = Date().timeIntervalSince(tappedQuit)
        XCTAssertLessThan(elapsed, 40, "\(name): the session ended, but \(elapsed)s after Quit; that is not the quit")
    }

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

    private var lastSeenStrip = ""
    private func lastStrip(_ hud: XCUIElement) -> String {
        if hud.exists { lastSeenStrip = hud.label }
        return lastSeenStrip
    }

    /// Same parse as DebugHUDInputTelemetryTests: the pad= segment's fields,
    /// a value running until the next known key.
    private func fields(of label: String) -> [String: String] {
        let keys = ["pad", "pads", "btn", "ly", "lypk", "vly", "ab", "mv", "menu"]
        var result: [String: String] = [:]
        for segment in label.components(separatedBy: "\n").flatMap({ $0.components(separatedBy: " · ") }) {
            guard segment.hasPrefix("pad=") else { continue }
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
