import XCTest
import notify

/// The half-open play layout (issue #373) in a live session: the game above
/// the fold, every control below it, and back again when the device opens
/// flat.
///
/// No simulator in CI has a hinge, and nothing Apple ships folds the iPhone
/// Duo simulator from a script (docs/learnings/iphone-duo-simulator-traps.md).
/// So this drives the layout through `WADDLE_TEST_HALF_OPEN`, which stands in
/// for the two things the system reports on a Duo: a hinge that is partly
/// open and a 40 pt band across the middle of the window. Everything
/// downstream of that reading is the shipping code: the engine moving the
/// picture, the overlay moving its controls, and menu taps landing on a
/// picture that is no longer in the middle of the window. That the system
/// does report those two things on a Duo was checked by hand; see
/// docs/learnings/iphone-duo-half-open-pose.md.
///
/// `HalfOpenSplitTests` (unit) pins the geometry with the Duo's own
/// measurements. This is the part only a session can show.
final class HalfOpenLayoutTests: XCTestCase {

    private let controls = ["fireButton", "useButton", "weaponPrevButton", "weaponNextButton",
                            "automapButton", "menuButton"]

    @MainActor
    func testGameStandsAboveTheFoldAndControlsBelowIt() throws {
        let (app, hud) = startSession(halfOpen: "1")

        // The marker is only there while the overlay is split, and carries
        // the rect the engine says it is drawing into.
        let marker = app.otherElements["halfOpenSplit"]
        XCTAssertTrue(marker.waitForExistence(timeout: 10), "the overlay never split")
        let window = app.frame
        let split = try XCTUnwrap(readSplit(marker), "unreadable marker: \(marker.value ?? "nil")")

        XCTAssertEqual(split.creaseTop, window.midY - 20, accuracy: 0.5, "the seam's band is 40 pt across the middle")
        XCTAssertEqual(split.creaseBottom, window.midY + 20, accuracy: 0.5)

        // The picture: wholly above the band, its own shape, centred.
        XCTAssertGreaterThanOrEqual(split.picture.minY, window.minY - 0.5, "\(split.picture)")
        XCTAssertLessThanOrEqual(split.picture.maxY, split.creaseTop + 0.5, "the picture crosses the fold: \(split.picture)")
        XCTAssertEqual(split.picture.width / split.picture.height, 4.0 / 3.0, accuracy: 0.01,
                       "a portrait phone's session is 4:3 and must stay 4:3 above the fold: \(split.picture)")
        XCTAssertEqual(split.picture.midX, window.midX, accuracy: 1, "\(split.picture)")
        XCTAssertGreaterThan(split.picture.width, window.width * 0.9,
                             "the picture should fill the upper half's width on a phone: \(split.picture)")

        // The controls: every one below the band.
        for id in controls {
            let frame = app.buttons[id].frame
            XCTAssertGreaterThanOrEqual(frame.minY, split.creaseBottom - 0.5, "\(id) is above the fold's margin: \(frame)")
        }

        // The stick is a control too. A drag on the picture starts nothing;
        // the same drag below the fold starts the stick.
        let stickEngaged = app.otherElements["stickEngaged"]
        drag(app, fromY: 0.20, toY: 0.30)
        XCTAssertFalse(stickEngaged.waitForExistence(timeout: 2), "a drag on the picture started the stick")
        drag(app, fromY: 0.75, toY: 0.85)
        XCTAssertTrue(stickEngaged.waitForExistence(timeout: 3), "a drag below the fold should start the stick")

        // The menu is drawn on the picture, wherever the picture is: its
        // items are reported inside the confined rect, and a tap on one
        // opens it.
        let main = openMainMenu(app, hud)
        XCTAssertEqual(main["cm"], "main", "the main menu should be up: \(lastSeenStrip)")
        let targets = points(main["tgt"])
        XCTAssertGreaterThanOrEqual(targets.count, 5, "main-menu item centres: \(lastSeenStrip)")
        for target in targets {
            XCTAssertTrue(split.picture.insetBy(dx: -0.5, dy: -0.5).contains(target),
                          "menu item at \(target) is outside the picture \(split.picture)")
        }
        tap(app, targets[2]) // Load Game
        let load = waitForHUD(hud, timeout: 5) { $0["cm"] == "load" }
        XCTAssertEqual(load["cm"], "load", "a tap on Load Game, above the fold, should open it: \(lastSeenStrip)")
        closeMenus(app, hud)

        // Open flat: the normal layout comes back mid-session.
        notify_post("com.tylervick.waddle.test.half-open-toggle")
        XCTAssertTrue(waitUntil(timeout: 5) { !marker.exists }, "the overlay stayed split after opening flat")
        XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["menuButton"].frame.maxY < split.creaseTop },
                      "the menu button should be back at the top of the window: \(app.buttons["menuButton"].frame)")
        XCTAssertLessThan(app.buttons["automapButton"].frame.maxY, split.creaseTop)

        // And half open again.
        notify_post("com.tylervick.waddle.test.half-open-toggle")
        XCTAssertTrue(marker.waitForExistence(timeout: 5), "the overlay did not split again")
        let again = try XCTUnwrap(readSplit(marker))
        XCTAssertLessThanOrEqual(again.picture.maxY, again.creaseTop + 0.5, "\(again.picture)")
        XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["menuButton"].frame.minY >= again.creaseBottom - 0.5 },
                      "the menu button should be below the fold again: \(app.buttons["menuButton"].frame)")

        releaseAutoquit()
        let exitLabel = app.staticTexts["engineExitLabel"]
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90), "engine never returned to the launcher")
        XCTAssertEqual(exitLabel.label, "Engine exited: 0")
    }

    /// Folding the device under a thumb that is already steering. A stick
    /// that began above where the fold lands would go on working from on top
    /// of the picture, so the overlay lets go of it; one that began below
    /// the fold is still in the controls' half and is kept.
    ///
    /// A test cannot fold the device at the moment a finger is down: the
    /// drag is one blocking call. `WADDLE_TEST_HALF_OPEN=stick` makes the
    /// app do it, on the turn of the run loop after a stick begins flat. The
    /// marker then reports how many held tracks the fold let go of.
    @MainActor
    func testFoldingUnderAHeldStickLetsGoOfItOnlyAboveTheFold() throws {
        let (app, hud) = startSession(halfOpen: "stick")
        let marker = app.otherElements["halfOpenSplit"]
        XCTAssertFalse(marker.exists, "the session should start flat")

        // Above where the fold will be.
        drag(app, fromY: 0.20, toY: 0.30)
        XCTAssertTrue(app.otherElements["stickEngaged"].waitForExistence(timeout: 3),
                      "flat, a drag in the upper half should start the stick")
        XCTAssertTrue(marker.waitForExistence(timeout: 5), "the overlay did not fold under the stick")
        let first = try XCTUnwrap(readSplit(marker), "unreadable marker: \(marker.value ?? "nil")")
        XCTAssertEqual(first.released, 1, "the stick held above the fold should have been let go: \(marker.value ?? "nil")")

        // Open flat, then the same again from below where the fold will be.
        notify_post("com.tylervick.waddle.test.half-open-toggle")
        XCTAssertTrue(waitUntil(timeout: 5) { !marker.exists }, "the overlay stayed split after opening flat")
        drag(app, fromY: 0.75, toY: 0.85)
        XCTAssertTrue(marker.waitForExistence(timeout: 5), "the overlay did not fold under the second stick")
        let second = try XCTUnwrap(readSplit(marker), "unreadable marker: \(marker.value ?? "nil")")
        XCTAssertEqual(second.released, 1, "a stick held below the fold should have been kept: \(marker.value ?? "nil")")

        // On the title screen the kept stick's movement opens the menu.
        if waitForHUD(hud, timeout: 2, until: { $0["cm"] != "off" })["cm"] != "off" { closeMenus(app, hud) }
        releaseAutoquit()
        let exitLabel = app.staticTexts["engineExitLabel"]
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90), "engine never returned to the launcher")
        XCTAssertEqual(exitLabel.label, "Engine exited: 0")
    }

    // MARK: helpers

    /// Launches into a Freedoom Phase 2 session with the overlay forced on
    /// and the fold's test seam in the given state.
    @MainActor
    private func startSession(halfOpen: String) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "20"
        app.holdAutoquit()
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launchEnvironment["WADDLE_TEST_HALF_OPEN"] = halfOpen
        app.launchArguments += ["-debugHUD", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90), "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }

        let phase2 = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'game-' AND identifier CONTAINS 'Freedoom Phase 2'")).firstMatch
        XCTAssertTrue(phase2.waitForExistence(timeout: 30), "Phase 2 tile missing")
        phase2.tap()

        let hud = app.staticTexts["sessionDebugHUD"]
        XCTAssertTrue(hud.waitForExistence(timeout: 30), "debug HUD never appeared")
        XCTAssertTrue(app.buttons["fireButton"].waitForExistence(timeout: 30), "overlay never installed")
        return (app, hud)
    }

    private struct Split {
        let picture: CGRect
        let creaseTop: CGFloat
        let creaseBottom: CGFloat
        /// Held tracks a fold has let go of since the session began.
        let released: Int?
    }

    /// "picture=x,y,w,h crease=top,bottom released=n", window points.
    @MainActor
    private func readSplit(_ marker: XCUIElement) -> Split? {
        guard let value = marker.value as? String else { return nil }
        var numbers: [String: [CGFloat]] = [:]
        for pair in value.split(separator: " ") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            numbers[String(kv[0])] = kv[1].split(separator: ",").compactMap { Double($0).map { CGFloat($0) } }
        }
        guard let p = numbers["picture"], p.count == 4, let c = numbers["crease"], c.count == 2 else { return nil }
        return Split(picture: CGRect(x: p[0], y: p[1], width: p[2], height: p[3]),
                     creaseTop: c[0], creaseBottom: c[1],
                     released: numbers["released"]?.first.map { Int($0) })
    }

    /// A short vertical drag in the stick column, at the given heights.
    @MainActor
    private func drag(_ app: XCUIApplication, fromY: CGFloat, toY: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: fromY))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: toY))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.3)
    }

    /// The main menu, whatever is up now. On the title screen the stick drag
    /// above has already opened it, as any pad input does there, and a tap
    /// on the menu button would close it again; so look before tapping.
    @MainActor
    private func openMainMenu(_ app: XCUIApplication, _ hud: XCUIElement) -> [String: String] {
        var state = waitForHUD(hud, timeout: 2) { $0["cm"] == "main" }
        for _ in 0..<3 where state["cm"] != "main" {
            app.buttons["menuButton"].tap()
            state = waitForHUD(hud, timeout: 5) { $0["cm"] == "main" }
        }
        return state
    }

    /// The menu button closes every open menu; a second tap would reopen, so
    /// stop as soon as the HUD says off.
    @MainActor
    private func closeMenus(_ app: XCUIApplication, _ hud: XCUIElement) {
        for _ in 0..<3 {
            app.buttons["menuButton"].tap()
            if waitForHUD(hud, timeout: 3, until: { $0["cm"] == "off" })["cm"] == "off" { return }
        }
        XCTFail("could not close the menus: \(lastSeenStrip)")
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ p: CGPoint) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y)).tap()
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    private func points(_ s: String?) -> [CGPoint] {
        (s ?? "").split(separator: "|").compactMap { pair in
            let xy = pair.split(separator: ",")
            guard xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]) else { return nil }
            return CGPoint(x: x, y: y)
        }
    }

    @MainActor
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
    @MainActor
    private func lastStrip(_ hud: XCUIElement) -> String {
        if let strip = labelIfPresent(hud) { lastSeenStrip = strip }
        return lastSeenStrip
    }

    /// The `cm=` segment's plain `key=value` pairs.
    private func fields(of label: String) -> [String: String] {
        var result: [String: String] = [:]
        for segment in label.components(separatedBy: "\n").flatMap({ $0.components(separatedBy: " · ") })
        where segment.hasPrefix("cm=") {
            for pair in segment.split(separator: " ") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { result[String(kv[0])] = String(kv[1]) }
            }
        }
        return result
    }
}
