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
