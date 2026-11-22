import XCTest

/// Issue #440. The rows of the engine's setup screens take a press across
/// the whole width of the screen, but draw only a label and a setting in
/// the middle of it. Where an overlay button sits over the drawn part, a
/// touch there is a touch on the row (it used to press the button, which
/// changed the cursor's row instead or turned the tab); where it sits over
/// the empty part, it is still the button, so steering with the stick and
/// confirming with USE keeps working.
///
/// With the shipped layout that overlap exists on a closed iPhone Duo in
/// landscape (26 places, measured 2026-11-21) and nowhere on a landscape
/// iPhone 18 Pro, and XCUITest cannot turn a Duo. So this puts USE there
/// itself, with the layout editor's stored offsets, which is also where a
/// player can put it on any phone. `DuoLayoutSweepTests.testM_SetupScreens`
/// walks every row on a real Duo.
final class SetupScreenOverlapTests: XCTestCase {

    /// Options > Enemies, the seventh item.
    private let enemiesScreen = 6

    @MainActor
    func testATouchOnADrawnSetupRowUnderUSEActsOnTheRowAndBesideItPressesUSE() throws {
        XCUIDevice.shared.orientation = .portrait
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }

        let (app, hud, walker, rowIndex, row, onRow, beside) = try launchWithUSEAcrossTheEndOfARow()
        let state = try XCTUnwrap(app.setupProbeState())
        XCTAssertTrue(row.press.contains(beside), "\(beside) should be inside the row's press rect \(row.press)")
        XCTAssertFalse(state.items.contains { $0.touchable.insetBy(dx: -2, dy: -2).contains(beside) }
                        || state.tabs.contains { $0.insetBy(dx: -2, dy: -2).contains(beside) },
                       "\(beside) should be on nothing the screen draws")
        let original = row.value

        // On the drawn part, under USE: the row's, and the row flips.
        var presses = try XCTUnwrap(walker.hudNumber("mt"))
        var buttonEvents = try XCTUnwrap(walker.hudNumber("btn"))
        walker.tap(onRow)
        let flipped = walker.wait(5) { () -> SetupProbeState? in
            guard let now = app.setupProbeState(), rowIndex < now.items.count,
                  now.items[rowIndex].value != original else { return nil }
            return now
        }
        XCTAssertNotNil(flipped, "a touch at \(onRow), on the row's setting under USE, should flip the row: "
                        + "\(app.setupProbeState().map { "\($0.items[rowIndex])" } ?? "no setup screen is up")")
        Thread.sleep(forTimeInterval: 1) // the HUD's next refresh
        XCTAssertGreaterThan(try XCTUnwrap(walker.hudNumber("mt")), presses, "the menu should have been sent the press")
        XCTAssertEqual(walker.hudNumber("btn"), buttonEvents, "USE must not have been pressed by a touch on the row")
        XCTAssertEqual(app.setupProbeState()?.cursor, rowIndex, "the cursor should be on the touched row")

        // On USE where the row draws nothing: still USE. It confirms the
        // cursor's row, which is the one just touched: the engine begins
        // changing it (`sel=1`), as it does for a pad's confirm button.
        presses = try XCTUnwrap(walker.hudNumber("mt"))
        buttonEvents = try XCTUnwrap(walker.hudNumber("btn"))
        walker.tap(beside)
        let confirmed = walker.wait(5) { () -> SetupProbeState? in
            guard let now = app.setupProbeState(), now.selecting, now.cursor == rowIndex else { return nil }
            return now
        }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertGreaterThan(try XCTUnwrap(walker.hudNumber("btn")), buttonEvents,
                             "a touch at \(beside), on USE beside what the row draws, should press USE")
        XCTAssertEqual(walker.hudNumber("mt"), presses, "the menu must not have been sent a press by a touch on USE")
        XCTAssertNotNil(confirmed, "USE should have confirmed the cursor's row: "
                        + "\(app.setupProbeState().map { "cursor \($0.cursor) selecting \($0.selecting)" } ?? "no setup screen is up")")

        // Leave the setting as it was found, whatever happened above.
        if let now = walker.open(screen: enemiesScreen, tab: 0), rowIndex < now.items.count,
           now.items[rowIndex].value != original {
            walker.tap(CGPoint(x: row.drawn.minX + 6, y: row.drawn.midY))
            let restored = walker.wait(5) { app.setupProbeState()?.items[rowIndex].value == original ? true : nil }
            XCTAssertNotNil(restored, "could not put the setting back to \(original)")
        }
        XCTAssertTrue(walker.closeMenus(), "≡ should still close the menu")
        releaseAutoquit()
        XCTAssertTrue(app.staticTexts["engineExitLabel"].waitForExistence(timeout: 60),
                      "engine never returned to the launcher")
        _ = hud
    }

    /// A session that ends with a setup screen still up must not leave the
    /// next one thinking it is in one (`MN_ResetSessionSetup`,
    /// docs/engine-session-globals.md). Without the reset the second
    /// session's main menu reported `cm=setup` with no item centres, its
    /// taps went to the setup screens' pointer code, and the rows the first
    /// session drew still took touches from a button over where they had
    /// been.
    @MainActor
    func testASessionEndedInsideASetupScreenLeavesTheNextOneItsMainMenuAndButtons() throws {
        XCUIDevice.shared.orientation = .portrait
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        // Session 1 ends here, with Options > Enemies up and USE over a row.
        let (app, hud, walker, _, _, onRow, _) = try launchWithUSEAcrossTheEndOfARow()
        XCTAssertNotNil(app.setupProbeState(), "the first session should end inside a setup screen")
        let exitLabel = app.staticTexts["engineExitLabel"]
        releaseAutoquit()
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90), "the first session never ended")

        // Session 2, same process.
        let play = app.buttons["playFreedoom1"]
        XCTAssertTrue(play.waitForExistence(timeout: 30), "the tile is missing after the first session")
        play.tap()
        XCTAssertTrue(exitLabel.waitForNonExistence(timeout: 15), "previous exit label never cleared")
        XCTAssertTrue(app.buttons["fireButton"].waitForExistence(timeout: 30), "overlay never installed again")
        XCTAssertTrue(hud.waitForExistence(timeout: 30), "debug HUD never appeared again")
        Thread.sleep(forTimeInterval: 5) // level load and screen wipe

        app.buttons["menuButton"].tap()
        let main = walker.wait(8) { () -> [CGPoint]? in
            let now = walker.menu()
            return now.name == "main" && now.targets.count >= 5 ? now.targets : nil
        }
        XCTAssertNotNil(main, "the second session's menu should be the main menu with its items: "
                        + "cm=\(walker.menu().name) tgt=\(walker.menu().targets)")
        XCTAssertNil(app.setupProbeState(), "no setup screen is up in the second session")

        // USE, where the first session's row was drawn: it is a button again.
        // (On the main menu it confirms New Game, so the menu changes.)
        let presses = try XCTUnwrap(walker.hudNumber("mt"))
        let buttonEvents = try XCTUnwrap(walker.hudNumber("btn"))
        walker.tap(onRow)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertGreaterThan(try XCTUnwrap(walker.hudNumber("btn")), buttonEvents,
                             "a touch on USE at \(onRow) should press USE in the second session")
        XCTAssertEqual(walker.hudNumber("mt"), presses,
                       "a row the first session drew must not take USE's touch in the second")

        // And the main menu is steered as a main menu: a tap opens Options.
        XCTAssertTrue(walker.closeMenus(), "≡ should close the menu")
        XCTAssertNotNil(walker.openOptions(), "a tap on the main menu's Options should open it: cm=\(walker.menu().name)")

        XCTAssertTrue(walker.closeMenus(), "≡ should close the menu")
        releaseAutoquit()
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 60), "the second session never ended")
    }

    /// Two launches, ending in a session with Options > Enemies up and USE
    /// moved so that its circle lies across the end of what the last on/off
    /// row draws (Randomly Mirrored Corpses, a cosmetic setting with no side
    /// effect): `onRow` is on USE and on the row's setting, `beside` is on
    /// USE where the row draws nothing. The first launch measures where the
    /// row draws and where USE is by default; the second carries the offset
    /// in the argument domain, for that launch only, so nothing is written
    /// to the app's defaults.
    @MainActor
    private func launchWithUSEAcrossTheEndOfARow() throws
        -> (XCUIApplication, XCUIElement, SetupScreenWalker, Int, SetupProbeItem, CGPoint, CGPoint) {
        // First launch: where the row draws, and where USE is by default.
        var (app, hud, walker) = try startLandscapeSession(arguments: [])
        var state = try XCTUnwrap(walker.open(screen: enemiesScreen, tab: 0), "the Enemies screen never opened")
        // The last on/off row the cursor can land on: Randomly Mirrored
        // Corpses, a cosmetic setting with no side effect.
        var rowIndex = try XCTUnwrap(state.items.lastIndex { $0.kind == "O" && !$0.skip },
                                     "no on/off row on the Enemies screen: \(state.items)")
        var row = state.items[rowIndex]
        let defaultUse = app.buttons["useButton"].frame
        XCTAssertGreaterThan(row.drawn.width, 0, "the row reports nothing drawn")
        // USE's circle across the end of what the row draws: its left over
        // the setting's last letters, its right over the empty rest of the
        // row. Offsets are stored in reference points; USE is 64 at scale 1.
        let scale = defaultUse.width / 64
        let target = CGPoint(x: row.drawn.maxX + defaultUse.width * 0.15, y: row.drawn.midY)
        let offset = [Double((target.x - defaultUse.midX) / scale), Double((target.y - defaultUse.midY) / scale)]
        walker.closeMenus()
        app.terminate()

        // Second launch, USE moved. The argument domain holds it for this
        // launch only; nothing is written to the app's defaults.
        let json = try JSONSerialization.data(withJSONObject: ["useButton": offset])
        let hex = json.map { String(format: "%02x", $0) }.joined()
        (app, hud, walker) = try startLandscapeSession(arguments: ["-touchOverlayLayoutOffsets", "<\(hex)>"])
        state = try XCTUnwrap(walker.open(screen: enemiesScreen, tab: 0), "the Enemies screen never opened again")
        rowIndex = try XCTUnwrap(state.items.lastIndex { $0.kind == "O" && !$0.skip })
        row = state.items[rowIndex]
        let use = app.buttons["useButton"].frame
        let radius = min(use.width, use.height) / 2
        attach(XCUIScreen.main.screenshot(), "use-over-a-setup-row")

        let onRow = try XCTUnwrap(
            setupProbeHits(row.touchable, buttons: [("useButton", use)]).first { $0.onButton }?.point,
            "USE at \(use) is not over what row \(rowIndex) draws, \(row.drawn)")
        let beside = CGPoint(x: use.midX + radius * 0.6, y: use.midY)
        return (app, hud, walker, rowIndex, row, onRow, beside)
    }

    @MainActor
    private func startLandscapeSession(arguments: [String]) throws
        -> (XCUIApplication, XCUIElement, SetupScreenWalker) {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "20"
        app.holdAutoquit()
        app.launchEnvironment["WADDLE_TEST_WARP"] = "1"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launchArguments += ["-debugHUD", "YES"] + arguments
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
        Thread.sleep(forTimeInterval: 5) // level load and screen wipe
        let walker = SetupScreenWalker(app: app, hud: hud) { point in
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        }
        return (app, hud, walker)
    }

    private func attach(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
