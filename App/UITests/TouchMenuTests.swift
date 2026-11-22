import XCTest

/// Woof's menus driven by touch (docs/superpowers/specs/2026-10-05-touch-menus-design.md).
/// The debug HUD's third segment (`WoofIOS_DebugMenuState`) reports which
/// menu is up and where its items are on screen, so this test taps real
/// screen points and reads back what the engine did.
///
/// Format of that segment: `cm=<menu> msg=<0|1> mp=<n> mt=<n> md=<n>
/// iw=<n> tgt=<x,y|x,y|...>` -- current menu name, prompt showing, pointer
/// writes, press/release writes, presses dropped, an item's width and the
/// item centres, both in window points.
final class TouchMenuTests: XCTestCase {

    private let autoquitSeconds = 120.0

    @MainActor
    func testTapsOpenMenusAndPromptsNeedTheButtons() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
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
        let booted = waitForHUD(hud, timeout: 30) { $0["pad"]?.hasSuffix(" virtual") == true }
        XCTAssertEqual(booted["pad"]?.hasSuffix(" virtual"), true, "engine should hold our pad: \(lastSeenStrip)")
        XCTAssertEqual(booted["cm"], "off", "no menu on the title screen: \(lastSeenStrip)")
        XCTAssertFalse(app.buttons["promptYesButton"].exists, "Yes must be hidden with no prompt up")

        // Title screen: a tap on the game opens the main menu.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        let opened = waitForHUD(hud, timeout: 5) { $0["cm"] == "main" }
        XCTAssertEqual(opened["cm"], "main", "a title-screen tap should open the menu: \(lastSeenStrip)")
        closeMenus(app, hud)

        // A pointer tap outside the stick column opens the item under it.
        app.buttons["menuButton"].tap()
        var main = waitForHUD(hud, timeout: 10) { $0["cm"] == "main" }
        var targets = points(main["tgt"])
        XCTAssertGreaterThanOrEqual(targets.count, 5, "main-menu item centres: \(lastSeenStrip)")

        // Empty space above New Game: a press there is eaten, nothing opens.
        tap(app, CGPoint(x: targets[0].x, y: targets[0].y - 60))
        Thread.sleep(forTimeInterval: 0.75)
        let stillMain = waitForHUD(hud, timeout: 1) { _ in false }
        XCTAssertEqual(stillMain["cm"], "main", "a tap on empty menu space must change nothing: \(lastSeenStrip)")

        tap(app, targets[2]) // Load Game; the centre is right of the stick column
        let load = waitForHUD(hud, timeout: 5) { $0["cm"] == "load" }
        XCTAssertEqual(load["cm"], "load", "one tap should open Load Game: \(lastSeenStrip)")

        // A tap in the stick column (left 40%) is pending until it lifts in
        // place, then it is a tap on the row under it: Options, index 1.
        closeMenus(app, hud)
        app.buttons["menuButton"].tap()
        main = waitForHUD(hud, timeout: 10) { $0["cm"] == "main" }
        targets = points(main["tgt"])
        XCTAssertGreaterThanOrEqual(targets.count, 5, "\(lastSeenStrip)")
        let stickColumnX = app.frame.width * 0.2
        tap(app, CGPoint(x: stickColumnX, y: targets[1].y))
        let options = waitForHUD(hud, timeout: 5) { $0["cm"] == "options" }
        XCTAssertEqual(options["cm"], "options", "a lift-in-place in the stick column should tap Options: \(lastSeenStrip)")

        // A drag in the stick column is still the stick, and it still moves
        // the menu cursor (DebugHUDInputTelemetryTests pins the counters).
        closeMenus(app, hud)
        app.buttons["menuButton"].tap()
        main = waitForHUD(hud, timeout: 10) { $0["cm"] == "main" }
        let movesBefore = Int(main["mv"] ?? "") ?? 0
        let stickStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.72))
        let stickEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.90))
        stickStart.press(forDuration: 0.2, thenDragTo: stickEnd, withVelocity: .fast, thenHoldForDuration: 1.0)
        let afterDrag = waitForHUD(hud, timeout: 10) { (Int($0["mv"] ?? "") ?? 0) > movesBefore }
        XCTAssertGreaterThan(Int(afterDrag["mv"] ?? "") ?? 0, movesBefore,
                             "a stick drag with the menu up must still navigate it: \(lastSeenStrip)")
        XCTAssertEqual(afterDrag["cm"], "main", "the drag must not have tapped anything: \(lastSeenStrip)")

        // Quit shows a prompt. A tap on it is dropped; No closes it; Yes quits.
        closeMenus(app, hud)
        app.buttons["menuButton"].tap()
        main = waitForHUD(hud, timeout: 10) { $0["cm"] == "main" }
        targets = points(main["tgt"])
        XCTAssertGreaterThanOrEqual(targets.count, 5, "\(lastSeenStrip)")
        tap(app, targets[targets.count - 1]) // Quit is last
        let prompt = waitForHUD(hud, timeout: 5) { $0["msg"] == "1" }
        XCTAssertEqual(prompt["msg"], "1", "Quit should show its prompt: \(lastSeenStrip)")
        XCTAssertTrue(app.buttons["promptYesButton"].waitForExistence(timeout: 3), "Yes should appear with the prompt")
        XCTAssertTrue(app.buttons["promptNoButton"].exists, "No should appear with the prompt")
        let droppedBefore = Int(prompt["md"] ?? "") ?? 0
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        Thread.sleep(forTimeInterval: 0.75)
        let afterPromptTap = waitForHUD(hud, timeout: 1) { _ in false }
        XCTAssertEqual(afterPromptTap["msg"], "1", "the prompt must survive a tap: \(lastSeenStrip)")
        XCTAssertGreaterThan(Int(afterPromptTap["md"] ?? "") ?? 0, droppedBefore,
                             "the press should be counted as dropped: \(lastSeenStrip)")

        app.buttons["promptNoButton"].tap()
        let declined = waitForHUD(hud, timeout: 5) { $0["msg"] == "0" }
        XCTAssertEqual(declined["msg"], "0", "No should dismiss the prompt: \(lastSeenStrip)")
        XCTAssertEqual(declined["cm"], "off", "answering a prompt closes the whole menu: \(lastSeenStrip)")
        XCTAssertTrue(waitUntil(timeout: 3) { !app.buttons["promptNoButton"].exists }, "No should hide with the prompt")

        app.buttons["menuButton"].tap()
        main = waitForHUD(hud, timeout: 10) { $0["cm"] == "main" }
        targets = points(main["tgt"])
        XCTAssertGreaterThanOrEqual(targets.count, 5, "\(lastSeenStrip)")
        tap(app, targets[targets.count - 1])
        XCTAssertTrue(app.buttons["promptYesButton"].waitForExistence(timeout: 5), "Yes should appear again")
        app.buttons["promptYesButton"].tap()
        XCTAssertTrue(app.staticTexts["engineExitLabel"].waitForExistence(timeout: 90),
                      "Yes should quit the session")
    }

    /// Issue #430. Where the picture fills the window the overlay's buttons
    /// are drawn over the right-hand end of the engine's save list, and a
    /// touch there used to go to the button: on a closed iPhone Duo in
    /// landscape USE closed the list from slots 7 and 8, and FIRE (and its
    /// near-miss cushion) swallowed the touch. A touch on a slot now chooses
    /// the slot wherever along its frame it lands.
    ///
    /// The points are computed, not fixed (`saveSlotAimsUnderButtons`): each
    /// of the four right-hand buttons against each slot, kept when the point
    /// lies on the button or inside its cushion. A device whose buttons
    /// clear the list has no such point and the case skips, saying what it
    /// measured. On a landscape iPhone 18 Pro there are several, and with
    /// the hit-test override taken out every one of them fails.
    @MainActor
    func testATouchOnASaveSlotUnderAButtonChoosesTheSlot() throws {
        XCUIDevice.shared.orientation = .portrait
        // docs/learnings/simulator-test-hazards.md: never leave a rotation.
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "20"
        app.holdAutoquit()
        app.launchEnvironment["WADDLE_TEST_WARP"] = "1" // a level: nothing saves from the title
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launchArguments += ["-debugHUD", "YES"]
        app.launch()
        let play = app.buttons["playFreedoom1"]
        XCTAssertTrue(play.waitForExistence(timeout: 90), "launcher UI never appeared")

        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2)
        try XCTSkipUnless(app.frame.width > app.frame.height,
            "this simulator does not perform interface rotation; run on one that does")

        play.tap()
        let hud = app.staticTexts["sessionDebugHUD"]
        XCTAssertTrue(hud.waitForExistence(timeout: 30), "debug HUD never appeared")
        XCTAssertTrue(app.buttons["fireButton"].waitForExistence(timeout: 30), "overlay never installed")
        let inLevel = waitForHUD(hud, timeout: 30) { $0["pad"]?.hasSuffix(" virtual") == true }
        XCTAssertEqual(inLevel["pad"]?.hasSuffix(" virtual"), true, "engine should hold our pad: \(lastSeenStrip)")

        let list = try XCTUnwrap(openSaveList(app, hud), "the save list never opened: \(lastSeenStrip)")
        let slots = points(list["tgt"])
        let slotWidth = CGFloat(Double(list["iw"] ?? "") ?? 0)
        XCTAssertEqual(slots.count, 8, "save-slot centres: \(lastSeenStrip)")
        XCTAssertGreaterThan(slotWidth, 0, "the save slots' width: \(lastSeenStrip)")
        attachScreenshot(named: "save-list-landscape")

        let (aims, measured) = app.saveSlotAimsUnderButtons(slots: slots, slotWidth: slotWidth)
        try XCTSkipIf(aims.isEmpty, "no button is drawn over the save list here: \(measured)")
        XCTContext.runActivity(named: "aims: \(aims.map(\.what)); \(measured)") { _ in }

        let naming = app.otherElements["softKeyboardActive"]
        for aim in aims {
            // Whatever the last touch did, start from the list with no entry.
            if waitForHUD(hud, timeout: 2, until: { $0["cm"] == "save" })["cm"] != "save" {
                _ = try XCTUnwrap(openSaveList(app, hud), "the save list did not reopen: \(lastSeenStrip)")
            }
            XCTAssertFalse(naming.exists, "a save-name entry was left over before \(aim.what)")

            tap(app, aim.point)
            XCTAssertTrue(naming.waitForExistence(timeout: 5),
                          "a touch on \(aim.what) should begin naming the slot: \(lastSeenStrip)")
            XCTAssertEqual(waitForHUD(hud, timeout: 2) { _ in false }["cm"], "save",
                           "a touch on \(aim.what) must leave the save list up: \(lastSeenStrip)")

            // Out through ≡, not Return: Return writes the save, and a saved
            // game turns the tile into the Continue hero for later tests.
            if naming.exists {
                app.buttons["menuButton"].tap()
                XCTAssertTrue(waitUntil(timeout: 5) { !naming.exists },
                              "≡ should leave the save-name entry after \(aim.what)")
            }
        }

        // The way back out still works with the list up, from wherever the
        // last touch left it.
        closeMenus(app, hud)
        releaseAutoquit()
        XCTAssertTrue(app.staticTexts["engineExitLabel"].waitForExistence(timeout: 60),
                      "engine never returned to the launcher")
    }

    // MARK: helpers

    /// ≡, then Save Game (the main menu's fourth item). Nil if either step
    /// did not arrive; the caller reports it.
    @MainActor
    private func openSaveList(_ app: XCUIApplication, _ hud: XCUIElement) -> [String: String]? {
        for _ in 0..<3 {
            let state = waitForHUD(hud, timeout: 1) { $0["cm"] == "off" || $0["cm"] == "main" }
            if state["cm"] == "main" { break }
            app.buttons["menuButton"].tap()
            if waitForHUD(hud, timeout: 5, until: { $0["cm"] == "main" })["cm"] == "main" { break }
        }
        let main = waitForHUD(hud, timeout: 5) { $0["cm"] == "main" && self.points($0["tgt"]).count >= 5 }
        let targets = points(main["tgt"])
        guard main["cm"] == "main", targets.count >= 5 else { return nil }
        tap(app, targets[3])
        let save = waitForHUD(hud, timeout: 5) { $0["cm"] == "save" && self.points($0["tgt"]).count == 8 }
        return save["cm"] == "save" ? save : nil
    }

    /// ≡ closes every open menu (MENU_ESCAPE clears them all); a second tap
    /// would reopen, so stop as soon as the HUD says off.
    @MainActor
    private func closeMenus(_ app: XCUIApplication, _ hud: XCUIElement) {
        for _ in 0..<3 {
            app.buttons["menuButton"].tap()
            if waitForHUD(hud, timeout: 3, until: { $0["cm"] == "off" })["cm"] == "off" { return }
        }
        XCTFail("could not close the menus: \(lastSeenStrip)")
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ p: CGPoint) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y)).tap()
    }

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

    /// `pad=` segment: values may hold spaces, so they run to the next known
    /// key. `cm=` segment: plain `key=value` pairs, split on spaces.
    private func fields(of label: String) -> [String: String] {
        let padKeys = ["pad", "pads", "btn", "ly", "lypk", "vly", "ab", "mv", "menu"]
        var result: [String: String] = [:]
        for segment in label.components(separatedBy: "\n").flatMap({ $0.components(separatedBy: " · ") }) {
            if segment.hasPrefix("pad=") {
                var rest = segment
                for (i, key) in padKeys.enumerated() {
                    guard let range = rest.range(of: "\(key)=") else { continue }
                    let after = rest[range.upperBound...]
                    let end = padKeys.dropFirst(i + 1).compactMap { after.range(of: " \($0)=")?.lowerBound }.min()
                        ?? after.endIndex
                    result[key] = String(after[..<end])
                    rest = String(after[end...])
                }
            } else if segment.hasPrefix("cm=") {
                for pair in segment.split(separator: " ") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 { result[String(kv[0])] = String(kv[1]) }
                }
            }
        }
        return result
    }
}
