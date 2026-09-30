import XCTest

/// The App Store screenshot capture, driven by Scripts/capture-screenshots.sh.
/// Attaches full-resolution screenshots for the script to export from the
/// xcresult into docs/app-store/screenshots/<device>/.
///
/// Committed and compiled with the other UI suites, not generated at capture
/// time (issue #158): while the script wrote this file from a heredoc and
/// deleted it again, the compiler never saw it, so PR #144's shell rewrite
/// updated every other suite and left this one navigating screens that no
/// longer existed -- six correctly named images of the wrong screens (#156).
/// Now a change that breaks the helpers this file calls breaks the build.
///
/// It runs only when the script asks: `WADDLE_SCREENSHOT_CAPTURE` in the
/// test process environment (the script sets it through xcodebuild's
/// `TEST_RUNNER_` prefix). Under an ordinary `mise run test` it skips, in
/// the same shape as `DemoLoopReplayTests`' DOOM2 gate -- skips, not fails,
/// because a full game session, a preset, a rotation and an iPadOS
/// multitasking flip have no place in a routine run, and a red suite there
/// would only teach people to ignore it.
///
/// The two tests are ordered deliberately (XCTest runs methods in selector
/// order): the in-game one runs FIRST because playing a base game stamps
/// `lastPlayed` (LibraryService.markPlayed saves synchronously, before the
/// blocking engine session starts), and that is what gives the menu test's
/// Play-tab shot a populated "Recently Played" section.
final class ScreenshotCaptureTests: XCTestCase {

    /// The modded game in the marketing shots. SCYTHE is a Doom-2-format map
    /// set, so import pairs it with Freedoom Phase 2 and puts it on the shelf
    /// as a game named after the file (spec §2.1) -- nothing to build by hand.
    private let moddedGame = "SCYTHE"
    /// Its row id on the game page, which shows the name without an extension
    /// (the Files screen's rows use the full filename).
    private let moddedFile = "SCYTHE"

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["WADDLE_SCREENSHOT_CAPTURE"] != nil,
            "screenshot capture runs only from Scripts/capture-screenshots.sh "
            + "(WADDLE_SCREENSHOT_CAPTURE not set). Skipping.")
        continueAfterFailure = false
    }

    /// The simulator boots (and stays) in portrait. Since the orientation fix
    /// (a9acd51) the app supports portrait too, so a portrait device now
    /// yields a genuinely portrait screenshot — still the wrong aspect for
    /// the App Store's landscape slots, just no longer a sideways one. The
    /// orientation only sticks once the app is frontmost, so call this right
    /// after every launch().
    private func forceLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.0)  // rotation animation
    }

    private func shoot(_ name: String) {
        Thread.sleep(forTimeInterval: 1.5)  // settle transitions/animations
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Navigation MUST fail loudly. The predecessor of these two helpers tapped
    /// the tab bar behind a bare `if tab.waitForExistence(...)`, with no
    /// assertion. When the shelf (PR #144) deleted that tab bar the helper
    /// stopped navigating and stopped complaining: every subsequent `shoot(...)`
    /// photographed whatever happened to be on screen, so a capture run emitted
    /// six correctly-named images of the wrong screens and exited 0 — straight
    /// into docs/app-store/screenshots/, which is what the App Store submission
    /// and README.md both read from. A silent miss is the worst outcome
    /// available to this script, strictly worse than a crash, because nothing
    /// downstream re-checks the pixels. Assert every step.

    /// `openGamePage`, `returnToShelf`, `openFiles`, `closeSettings`,
    /// `clearAndType`, and `renameField` are NOT defined here. They live in
    /// App/UITests/XCTestCase+UIHelpers.swift, which compiles into this same UI
    /// test target, and both already assert. Redeclaring them as private
    /// methods on this subclass does not shadow the extension — it is a compile
    /// error ("overriding declaration requires an 'override' keyword"), which
    /// is how the duplication was caught. Use the shared ones.

    /// Scrolls `element` into the hierarchy. Restored after being deleted as
    /// dead code in the shelf migration — it is needed again, for a new reason.
    /// SwiftUI's lazy containers (LazyVGrid on the shelf, List in Files) omit
    /// off-screen cells from the accessibility hierarchy entirely, so `exists`
    /// is false and no `waitForExistence` will ever change it. The seeded
    /// Continue hero pushes the shelf's LazyVGrid below the fold, and both the
    /// base tile and this test's own modded-game tile live in that grid.
    @discardableResult
    @MainActor
    private func scrollIntoView(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        for _ in 0..<6 {
            if element.exists { return true }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        return element.exists
    }

    /// Scrolls the game page until `element` can be tapped. Not the shared
    /// `scrollTo`: that swipes the whole app, and with the device forced to
    /// landscape (which only this test does) those swipes left the page at the
    /// top on the iOS 27 simulator -- scroll bar at 0% after six of them. A
    /// drag between two points inside the page's own collection view is
    /// resolved in the page's coordinates, whatever the device orientation.
    @MainActor
    private func scrollGamePage(_ app: XCUIApplication, to element: XCUIElement) {
        let page = app.collectionViews["gamePage"]
        XCTAssertTrue(page.waitForExistence(timeout: 5), "game page never appeared")
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            // Short steps, so the page stops as soon as `element` is in reach
            // instead of overshooting the sections above it under the bar.
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05,
                       thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(element.exists && element.isHittable,
                      "\(element) never scrolled into view on the game page")
    }

    /// Opens the player-settings sheet from the shelf's gear. The identifier is
    /// still `touchSchemeMenu` — deliberately kept across the Menu-to-sheet
    /// conversion so existing tests kept working.
    ///
    /// `@MainActor` to match the test methods below: without it, referencing
    /// `app.navigationBars` inside `XCTAssertTrue`'s autoclosure warns about
    /// main-actor isolation.
    @MainActor
    private func openPlayerSettings(_ app: XCUIApplication) {
        let gear = app.buttons["touchSchemeMenu"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "gear missing from the shelf")
        gear.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
                      "tapped the gear but the Settings sheet never appeared")
    }

    /// iPadOS 26 defaults to the "Windowed Apps" multitasking style. Since
    /// the orientation fix (a9acd51) the app no longer lands sideways in a
    /// letterboxed portrait window there — it opens upright and fills the
    /// screen — but the system still draws a window-resize grabber over the
    /// app's bottom-right corner, and it does not fade (still in frame
    /// minutes after launch). That belongs in no marketing shot, so this
    /// step survives the fix. No public simctl/defaults switch exists for
    /// the multitasking style, so flip Settings to "Full Screen Apps" the
    /// way a user would. Runs first (digits sort before letters in XCTest
    /// ordering); skipped on iPhone.
    @MainActor
    func test0_ConfigureIPadFullScreenMode() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()

        let candidates = ["Multitasking & Gestures", "Home Screen & Multitasking"]
        var pane: XCUIElement?
        for _ in 0..<6 {
            if let hit = candidates.map({ settings.staticTexts[$0] })
                .first(where: { $0.exists }) {
                pane = hit
                break
            }
            settings.swipeUp()
        }
        guard let pane else {
            XCTFail("multitasking settings pane not found")
            return
        }
        pane.tap()

        let fullScreen = settings.staticTexts["Full Screen Apps"]
        XCTAssertTrue(fullScreen.waitForExistence(timeout: 5),
                      "Full Screen Apps option not found")
        fullScreen.tap()
        Thread.sleep(forTimeInterval: 1.0)
        settings.terminate()
    }

    /// 05-ingame, 06-automap. Runs first of the two capture tests — see the
    /// class note on ordering.
    @MainActor
    func testA_InGameScreens() throws {
        let app = XCUIApplication()
        // Menu-free path in-game + overlay visible under XCUITest's phantom
        // controller; neither adds any on-screen debug chrome.
        app.launchEnvironment["WADDLE_TEST_WARP"] = "1"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launch()
        forceLandscape()

        let play = app.buttons["playFreedoom1"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()

        let fire = app.buttons["fireButton"]
        XCTAssertTrue(fire.waitForExistence(timeout: 30), "overlay never installed")
        Thread.sleep(forTimeInterval: 5)  // level load + screen wipe
        shoot("05-ingame")

        let automap = app.buttons["automapButton"]
        XCTAssertTrue(automap.waitForExistence(timeout: 5),
                      "automap button missing from the overlay")
        automap.tap()
        shoot("06-automap")

        app.terminate()  // don't leave the engine session running
    }

    /// 02-library, 03-preset-editor, 01-play-tab, 04-control-feel.
    @MainActor
    func testB_MenuScreens() throws {
        let app = XCUIApplication()
        // The one seam this test needs. Woof autosaves only from
        // `G_DoWorldDone` (level completion); testA warps in via `G_InitNew`
        // and never finishes the level, so it leaves no save and the shelf
        // draws no Continue hero — the shelf's headline affordance, missing
        // from the marketing shot. This gives the item testA played a save so
        // the hero renders. No debug HUD or other seams.
        app.launchEnvironment["WADDLE_SEED_CONTINUE_SAVE"] = "1"
        app.launch()
        forceLandscape()

        // Probe the shelf by its chrome, not by a tile. With the Continue hero
        // seeded above it, the LazyVGrid starts below the fold on a landscape
        // phone — and a LazyVGrid cell below the fold is absent from the
        // accessibility hierarchy entirely, not merely non-hittable, so
        // `app.buttons["playFreedoom1"]` does not exist and no wait will change
        // that. `importButton` is toolbar chrome and always present.
        XCTAssertTrue(app.buttons["importButton"].waitForExistence(timeout: 20),
                      "shelf never came up")

        // Files (Settings → Files): the grouped file manager (Base games /
        // Map sets / Add-ons), shot before the modded game exists so no
        // notice banner or in-use warning is on screen. Still the reliable,
        // non-lazy-grid place to confirm the provisioned WADs landed, the
        // same role Manage used to serve.
        openFiles(app)
        let scytheRow = app.descendants(matching: .any)
            .matching(identifier: "fileRow-SCYTHE.WAD").firstMatch
        XCTAssertTrue(scytheRow.waitForExistence(timeout: 30),
                      "provisioned WADs not adopted — run the warm-up launch first")
        shoot("02-library")
        closeSettings(app)

        // A map set is a game the moment it is imported (spec §2.1): SCYTHE
        // arrives already paired with Freedoom Phase 2, which is the story the
        // listing tells. Photograph that game's page, scrolled so Base game and
        // Maps & Add-ons share the frame on a landscape phone.
        let tile = app.buttons["game-\(moddedGame)"]
        XCTAssertTrue(scrollIntoView(app, tile), "\(moddedGame) tile missing from the shelf")
        openGamePage(app, tile: "game-\(moddedGame)")
        XCTAssertTrue(app.buttons["basePicker"].label.contains("Freedoom Phase 2"),
                      "\(moddedGame) is not paired with Freedoom Phase 2")
        // Scroll first: the file rows sit below the fold, and a lazy list's
        // off-screen rows are absent from the hierarchy, not merely hidden.
        scrollGamePage(app, to: app.buttons["addFileButton"])
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "fileRow-\(moddedFile)")
            .firstMatch.waitForExistence(timeout: 5),
                      "\(moddedGame)'s page does not list \(moddedFile)")
        shoot("03-preset-editor")

        // Back to the shelf for the home shot: one grid of base games and
        // modded games, tiles carrying extracted TITLEPIC art. This is what a
        // user sees on launch.
        //
        // The Continue hero is asserted, not hoped for. It renders only because
        // WADDLE_SEED_CONTINUE_SAVE gave testA's item a save (see the launch
        // above), and what `ShelfView.hasResumableSave` ultimately consults is
        // `EngineSaveSlot`'s filename-based resolution. If that ever becomes
        // content-aware, the seeded marker stops resolving and the hero quietly
        // vanishes from the marketing shot — the precise silent-wrong-image
        // failure this script was rewritten to eliminate (#156). Assert it.
        //
        // The filename stays `01-play-tab` on purpose. Renaming it here would
        // orphan the image that file currently holds and break README.md's
        // <img src>, while the replacement image does not exist yet — the
        // rename belongs with the re-capture, where the files are being
        // replaced anyway. See issue #127.
        returnToShelf(app)
        XCTAssertTrue(app.buttons["continueHero"].waitForExistence(timeout: 10),
                      "no Continue hero on the shelf — WADDLE_SEED_CONTINUE_SAVE did not take, "
                      + "and this shot would ship without the shelf's headline affordance")

        // The hero is capped against the viewport (#159, fixed in #168), so the
        // grid shows beside it. Assert the modded game's tile is on screen
        // before the shot: `exists` alone passes for a cell that is in the
        // hierarchy but scrolled off or covered.
        let shelfTile = app.buttons["game-\(moddedGame)"]
        XCTAssertTrue(shelfTile.exists && shelfTile.isHittable,
                      "\(moddedGame) tile not visible on the shelf -- the grid is hidden again")
        shoot("01-play-tab")


        // Control Feel, now two levels deep: the gear opens the Settings sheet
        // (a sheet since the rework, not a Menu), and Control Feel… opens its
        // own sheet on top of that. Both are dismissed so the run ends on the
        // shelf rather than leaving a sheet stacked over it.
        openPlayerSettings(app)
        let controlFeel = app.buttons["controlFeelButton"]
        XCTAssertTrue(controlFeel.waitForExistence(timeout: 5),
                      "Control Feel button missing from the Settings sheet")
        controlFeel.tap()
        XCTAssertTrue(app.buttons["controlFeelDoneButton"].waitForExistence(timeout: 5),
                      "Control Feel sheet never opened")
        shoot("04-control-feel")
        app.buttons["controlFeelDoneButton"].tap()
        let settingsDone = app.navigationBars["Settings"].buttons["Done"]
        XCTAssertTrue(settingsDone.waitForExistence(timeout: 5),
                      "Settings sheet did not survive dismissing Control Feel")
        settingsDone.tap()
    }
}
