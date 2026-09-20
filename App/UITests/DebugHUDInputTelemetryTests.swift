import XCTest

/// The in-game debug HUD reports what the engine sees of the touch overlay's
/// input: which gamepad the engine has open (and whether it is the overlay's
/// virtual pad), how many gamepad button events it has processed, and where
/// the menu cursor is. This is the telemetry a Revyl device run needs to say
/// WHY a USE tap or a stick drag did nothing in the menu (see
/// .revyl/tests/README.md, menu-state-across-sessions): the screenshots can
/// show the strip, and nothing else on a farm device is readable.
///
/// Format, one segment of the strip:
///     pad=<name> <virtual|foreign|none> pads=<count> btn=<events> menu=<item|off>
final class DebugHUDInputTelemetryTests: XCTestCase {

    private let autoquitSeconds = 20.0

    @MainActor
    func testHUDReportsTheVirtualPadButtonEventsAndMenuCursor() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        // UserDefaults reads launch arguments, so this flips the same
        // "Show Debug Info" setting the Player Settings toggle writes.
        app.launchArguments += ["-debugHUD", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }

        let phase2 = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'game-' AND identifier CONTAINS 'Freedoom Phase 2'"))
            .firstMatch
        XCTAssertTrue(phase2.waitForExistence(timeout: 30), "Phase 2 tile missing")
        phase2.tap()

        let hud = app.staticTexts["sessionDebugHUD"]
        XCTAssertTrue(hud.waitForExistence(timeout: 30), "debug HUD never appeared")

        // The engine boots and the overlay attaches its virtual pad on their
        // own schedule; wait for the strip to say the pad is open.
        let booted = waitForHUD(hud, timeout: 30) { $0["pad"]?.hasSuffix(" virtual") == true }
        XCTAssertEqual(booted["pad"]?.hasSuffix(" virtual"), true,
                       "engine should have the overlay's virtual pad open: \(lastSeenStrip)")
        XCTAssertEqual(booted["menu"], "off", "no menu should be up on the title screen: \(lastSeenStrip)")
        let buttonEventsBefore = Int(booted["btn"] ?? "") ?? -1
        XCTAssertGreaterThanOrEqual(buttonEventsBefore, 0, "btn field missing: \(lastSeenStrip)")

        // START opens the menu; the cursor rests on New Game (item 0).
        app.buttons["menuButton"].tap()
        let menuOpen = waitForHUD(hud, timeout: 10) { $0["menu"] == "0" }
        XCTAssertEqual(menuOpen["menu"], "0", "menu cursor should be on item 0 after START: \(lastSeenStrip)")

        // The stick, while the main menu is up: press in the overlay's stick
        // region (lower left) and drag down, holding at the end so the axis
        // stays deflected across several tics. The engine turns a held
        // left-stick axis into menu-down presses, so the cursor must leave
        // item 0. Before the fix this stayed at 0 with pad=... foreign: the
        // axes were read from the phantom controller, not from our pad.
        let stickStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.72))
        let stickEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.90))
        stickStart.press(forDuration: 0.2, thenDragTo: stickEnd, withVelocity: .fast,
                         thenHoldForDuration: 1.0)
        let afterStick = waitForHUD(hud, timeout: 10) { (Int($0["menu"] ?? "") ?? 0) > 0 }
        XCTAssertGreaterThan(Int(afterStick["menu"] ?? "") ?? 0, 0,
            "a held stick drag should move the menu cursor off item 0: \(lastSeenStrip)")

        // USE is gamepad confirm: one press is a down and an up event, on top
        // of START's two. (Whatever item it confirms is irrelevant here; a
        // START afterwards would close the whole menu, not step back, so the
        // stick check above comes first.)
        app.buttons["useButton"].tap()
        let afterUse = waitForHUD(hud, timeout: 10) {
            (Int($0["btn"] ?? "") ?? -1) >= buttonEventsBefore + 4
        }
        let buttonEventsAfter = Int(afterUse["btn"] ?? "") ?? -1
        XCTAssertGreaterThanOrEqual(buttonEventsAfter, buttonEventsBefore + 4,
            "START and USE should each have produced a down and an up event: \(lastSeenStrip)")

        XCTAssertTrue(app.staticTexts["engineExitLabel"].waitForExistence(timeout: 90),
                      "engine never returned to the launcher")
    }

    /// Polls the HUD until `condition` holds for its parsed fields or the
    /// timeout passes, and returns the last parse either way; the caller's
    /// assertion then names what was actually on screen.
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

    /// The HUD leaves with the session; reading `label` on a departed element
    /// is a hard failure that hides which field was wrong. Keep the last text
    /// seen so every assertion message can show it.
    private var lastSeenStrip = ""
    private func lastStrip(_ hud: XCUIElement) -> String {
        if hud.exists { lastSeenStrip = hud.label }
        return lastSeenStrip
    }

    /// Splits "… · pad=Virtual Gamepad virtual pads=1 btn=4 menu=0 · …" into
    /// the telemetry fields; a value runs until the next known key.
    private func fields(of label: String) -> [String: String] {
        let keys = ["pad", "pads", "btn", "menu"]
        var result: [String: String] = [:]
        for segment in label.components(separatedBy: " · ") {
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
