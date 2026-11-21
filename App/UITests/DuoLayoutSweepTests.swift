import XCTest

/// The iPhone Duo layout sweep (issue #357), driven by
/// Scripts/duo-layout-sweep.sh: walks every surface of the app and asks the
/// script to photograph each one from the host. The script runs it once per
/// pose and text size; the pictures are for a person to look at, so nothing
/// here judges a layout.
///
/// Committed and compiled with the other UI suites for the reason
/// `ScreenshotCaptureTests` is (issue #158), and gated the same way: it runs
/// only when `WADDLE_DUO_SWEEP_REQUEST` is in the test environment, which
/// only the script sets, and skips otherwise.
///
/// Shots are asked of the host and never taken with `XCUIScreen`, which
/// returns the outer display whatever the device is doing
/// (docs/learnings/iphone-duo-simulator-traps.md). The test writes `shot
/// <name>` to the request file and goes on once the script has answered it.
///
/// A sweep is worth more complete than strict: a surface that cannot be
/// reached in one pose must not cost the surfaces after it. So each surface
/// is one `XCTContext` activity, a step that cannot find its element records
/// a failure naming the surface and returns, and the script lists the shots
/// that never arrived. `continueAfterFailure` stays true for that.
///
/// One launch per surface, mostly. Getting back out of a screen is where the
/// Duo differs most between poses (an unlabelled back button in the status
/// column when closed, a panel with Done when open and wide), and a launch
/// costs a few seconds where a wrong guess costs every later shot.
final class DuoLayoutSweepTests: XCTestCase {

    private var requestPath = ""
    /// `closed`, `closed-landscape`, `open`, `open-tall` or `half-open`.
    private var pose = ""
    /// The imported game whose page is photographed: a map set paired with a
    /// base game, so the page has every section. The script provisions it.
    private let moddedGame = "SCYTHE"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let request = env["WADDLE_DUO_SWEEP_REQUEST"] else {
            throw XCTSkip("the Duo layout sweep runs only from Scripts/duo-layout-sweep.sh "
                          + "(WADDLE_DUO_SWEEP_REQUEST not set). Skipping.")
        }
        requestPath = request
        pose = env["WADDLE_DUO_SWEEP_POSE"] ?? "closed"
        continueAfterFailure = true
    }

    // MARK: talking to the script

    /// Asks the script for one thing and waits for its answer.
    ///
    /// A request is the line `<id> <what>` in the request file; the script
    /// answers by writing that id to `<request>.done`. The id is what makes a
    /// late answer harmless: when this gives up on a request and asks for the
    /// next thing, the script's answer to the old one names an id nobody is
    /// waiting for. (The script used to answer by deleting the request file,
    /// and a slow handler then deleted the next request, which read here as
    /// served.) The file is moved into place so the script never reads half a
    /// line, and is removed here, by the side that wrote it.
    @discardableResult
    private func ask(_ line: String, timeout: TimeInterval) -> Bool {
        let id = UUID().uuidString
        let staged = requestPath + ".staged", done = requestPath + ".done"
        do {
            try? FileManager.default.removeItem(atPath: requestPath)
            try "\(id) \(line)".write(toFile: staged, atomically: true, encoding: .utf8)
            try FileManager.default.moveItem(atPath: staged, toPath: requestPath)
        } catch {
            XCTFail("could not ask the host for '\(line)': \(error)")
            return false
        }
        defer { try? FileManager.default.removeItem(atPath: requestPath) }
        func answered() -> Bool {
            (try? String(contentsOfFile: done, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) == id
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !answered() && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !answered() {
            XCTFail("the host did not serve '\(line)' within \(Int(timeout)) s")
            return false
        }
        return true
    }

    private func shoot(_ name: String, settle: TimeInterval = 1.5) {
        Thread.sleep(forTimeInterval: settle)
        ask("shot \(name)", timeout: 60)
    }

    private var isOpen: Bool { pose.hasPrefix("open") || pose == "half-open" }
    private var wantsLandscape: Bool { pose == "closed-landscape" }

    /// A long press on `element`. On an open device a press or a drag
    /// synthesized by XCUITest does nothing, so there the host is asked to
    /// make the touch through Device Hub, at the element's place in the
    /// app's points (`touch x,y,ms ...`: down at the first point for its ms,
    /// then to each later point over that point's ms).
    @MainActor
    private func longPress(_ element: XCUIElement) {
        guard isOpen else { element.press(forDuration: 1.0); return }
        let frame = element.frame
        ask("touch \(Int(frame.midX)),\(Int(frame.midY)),1200", timeout: 60)
    }

    /// Moves the content under the middle of `area` up by about a third
    /// of the window: a slow drag, not a flick, so a row is not thrown past.
    @MainActor
    private func scrollUp(_ app: XCUIApplication, in area: CGRect) {
        guard isOpen else {
            let from = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: area.midX, dy: area.minY + area.height * 0.7))
            let to = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: area.midX, dy: area.minY + area.height * 0.35))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
            return
        }
        // `app.frame` and every element frame are in the app's own points on
        // an open device too; only the window's reported shape is wrong.
        let x = Int(area.midX), from = Int(area.minY + area.height * 0.7), to = Int(area.minY + area.height * 0.35)
        ask("touch \(x),\(from),60 \(x),\(to),500 \(x),\(to),300", timeout: 60)
    }

    // MARK: launching

    /// Launches and, on a closed device, makes sure the interface is the way
    /// up this run is for. A rotation made from the host while no app is
    /// frontmost does not always reach the app launched next, so when it has
    /// not, the script is asked to turn the device away and back now.
    /// `app.frame` is not believed on an open device (it reports the wide
    /// window as tall); there the script judges the pose from each shot.
    @MainActor
    private func launch(env: [String: String] = [:], arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        for (key, value) in env { app.launchEnvironment[key] = value }
        app.launchArguments += arguments
        app.launch()
        guard !isOpen else { return app }
        let deadline = Date().addingTimeInterval(45)
        func right() -> Bool { (app.frame.width > app.frame.height) == wantsLandscape }
        while !right() && Date() < deadline {
            ask("turn", timeout: 30)
            Thread.sleep(forTimeInterval: 2)
        }
        XCTAssertTrue(right(), "the interface is \(app.frame.size) in pose '\(pose)'")
        return app
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 15) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }
        XCTFail("[\(pose)] \(what) never appeared")
        return false
    }

    /// How many drags the last `bringIntoView` made; 0 means the element was
    /// in reach already and the screen did not move.
    private var dragsMade = 0

    /// Scrolls `container` (the whole window when nil) until `element` is in
    /// reach. Says whether it got there, and fails nothing: the caller
    /// decides what an unreachable element costs.
    @MainActor
    private func bringIntoView(_ element: XCUIElement, in app: XCUIApplication,
                               scrolling container: XCUIElement? = nil, drags: Int = 30) -> Bool {
        // Its centre, not its whole frame: at the largest text sizes a shelf
        // tile is taller than a landscape window and never fits in it. A
        // centre on screen still rules out the sliver at the bottom edge
        // that `isHittable` alone accepts (issue #352).
        func reachable() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let frame = element.frame
            return app.windows.firstMatch.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        // Where to drag, settled once: a list found by one of its rows stops
        // being found when that row scrolls away, and the drags after that
        // would fall on whatever else is in the window.
        let window = app.windows.firstMatch.frame
        var area = window
        if let container, container.exists { area = container.frame.intersection(window) }
        dragsMade = 0
        while !reachable() && dragsMade < drags {
            scrollUp(app, in: area)
            Thread.sleep(forTimeInterval: 0.6)
            dragsMade += 1
        }
        return reachable()
    }

    // MARK: the session and the engine's own screens

    /// Taps the Freedoom Phase 1 tile, scrolled into reach first: at the
    /// largest text sizes the shelf is one column of tiles a window tall, and
    /// a tile can be in the hierarchy and off the screen.
    @MainActor
    private func tapFreedoomTile(_ app: XCUIApplication) -> Bool {
        let tile = app.buttons["playFreedoom1"]
        guard waitFor(app.buttons["importButton"], "the shelf", timeout: 30) else { return false }
        guard bringIntoView(tile, in: app, drags: 40) else {
            XCTFail("[\(pose)] the Freedoom Phase 1 tile could not be reached"); return false
        }
        tile.tap()
        return true
    }

    @MainActor
    private func startSession(_ app: XCUIApplication) -> Bool {
        guard tapFreedoomTile(app) else { return false }
        return waitFor(app.buttons["fireButton"], "the touch overlay", timeout: 40)
    }

    /// 20-session: a level with the touch controls up, no debug chrome.
    @MainActor
    func testA_Session() throws {
        let app = launch(env: ["WADDLE_TEST_WARP": "1", "WADDLE_FORCE_TOUCH_OVERLAY": "1"])
        defer { app.terminate() }
        guard startSession(app) else { return }
        Thread.sleep(forTimeInterval: 5)  // level load and screen wipe
        if pose == "half-open" {
            // The overlay's own word that it has split: the hinge reads
            // partly open and the fold runs across the window.
            XCTAssertTrue(app.otherElements["halfOpenSplit"].waitForExistence(timeout: 10),
                          "the device is posed half open and the overlay has not split")
        }
        shoot("20-session")
    }

    /// 21 to 24: the engine's menu, its save list, the save-name entry with
    /// the keyboard up, and the quit prompt. The debug HUD is on for these,
    /// because its `tgt=` field is where the menu's items are on screen and
    /// that is what the taps are aimed by; it also prints the window's size.
    @MainActor
    func testB_EngineMenus() throws {
        let app = launch(env: ["WADDLE_TEST_WARP": "1", "WADDLE_FORCE_TOUCH_OVERLAY": "1"],
                         arguments: ["-debugHUD", "YES"])
        defer { app.terminate() }
        guard startSession(app) else { return }
        let hud = app.staticTexts["sessionDebugHUD"]
        guard waitFor(hud, "the debug HUD", timeout: 30) else { return }
        Thread.sleep(forTimeInterval: 5)

        guard let main = openMainMenu(app, hud) else { return }
        shoot("21-engine-menu")

        // New Game, Options, Load Game, Save Game, Quit.
        guard main.count >= 5 else { XCTFail("[\(pose)] main menu items: \(main)"); return }
        tap(app, main[3])
        let save = waitForMenu(hud, "save")
        guard !save.isEmpty else { XCTFail("[\(pose)] the save list never opened"); return }
        shoot("22-engine-save-list")

        tap(app, save[0])
        if waitFor(app.otherElements["softKeyboardActive"], "the save-name keyboard", timeout: 10) {
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
            shoot("23-engine-save-name-keyboard", settle: 2.5)
            // Left through the menu button, not Return: Return would write
            // the save, and a saved game turns its tile into the Continue
            // hero for every test after this one.
        }

        // Whatever is still up, close it, then ask to quit.
        for _ in 0..<3 where menuName(hud) != "off" {
            app.buttons["menuButton"].tap()
            Thread.sleep(forTimeInterval: 1)
        }
        guard let again = openMainMenu(app, hud), let quit = again.last else { return }
        tap(app, quit)
        if waitFor(app.buttons["promptYesButton"], "the quit prompt's Yes button", timeout: 8) {
            shoot("24-engine-quit-prompt")
        }
    }

    @MainActor
    private func openMainMenu(_ app: XCUIApplication, _ hud: XCUIElement) -> [CGPoint]? {
        guard waitFor(app.buttons["menuButton"], "the menu button", timeout: 10) else { return nil }
        app.buttons["menuButton"].tap()
        let targets = waitForMenu(hud, "main")
        if targets.isEmpty { XCTFail("[\(pose)] the engine's main menu never opened"); return nil }
        return targets
    }

    /// A tap at a point of the app's window. On an open device the host
    /// makes it: XCUITest believes the wide window is tall there, and a tap
    /// aimed by coordinate (not by element) did not open the menu item under
    /// it.
    @MainActor
    private func tap(_ app: XCUIApplication, _ p: CGPoint) {
        if isOpen {
            ask("touch \(Int(p.x)),\(Int(p.y)),250", timeout: 60)
        } else {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y)).tap()
        }
    }

    /// The `cm=` and `tgt=` fields of the debug HUD: which menu is up and
    /// where its items' centres are, in window points.
    @MainActor
    private func menuState(_ hud: XCUIElement) -> (name: String, targets: [CGPoint]) {
        var name = "", targets: [CGPoint] = []
        for word in (labelIfPresent(hud) ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            if word.hasPrefix("cm=") { name = String(word.dropFirst(3)) }
            if word.hasPrefix("tgt=") {
                targets = word.dropFirst(4).split(separator: "|").compactMap { pair in
                    let xy = pair.split(separator: ",")
                    guard xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]) else { return nil }
                    return CGPoint(x: x, y: y)
                }
            }
        }
        return (name, targets)
    }

    @MainActor
    private func menuName(_ hud: XCUIElement) -> String { menuState(hud).name }

    @MainActor
    private func waitForMenu(_ hud: XCUIElement, _ name: String, timeout: TimeInterval = 10) -> [CGPoint] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = menuState(hud)
            if state.name == name && !state.targets.isEmpty { return state.targets }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return []
    }

    /// 30-engine-error-box, 31-launcher-error-alert: a session that dies in
    /// `I_Error` shows the engine's own box and then the launcher's alert.
    /// The failing input is `EngineErrorAlertDismissalTests`' zip.
    @MainActor
    func testC_EngineError() throws {
        let wad = SessionStartStateTests.pwad(lumpData: Data("WADDLE".utf8))
        let badID = SessionStartStateTests.storedZip(name: "waddle-test.wad",
                                                     data: Data("X".utf8) + wad.dropFirst())
        let app = launch(env: ["WADDLE_TEST_ZIP_1": badID.base64EncodedString()])
        defer { app.terminate() }
        guard tapFreedoomTile(app) else { return }
        let engineBox = app.alerts.matching(NSPredicate(format: "label BEGINSWITH 'Woof'")).firstMatch
        guard waitFor(engineBox, "the engine's error box", timeout: 60) else { return }
        shoot("30-engine-error-box")
        engineBox.buttons["OK"].tap()
        let launcherAlert = app.alerts["Couldn't run this game"]
        guard waitFor(launcherAlert, "the launcher's error alert", timeout: 15) else { return }
        shoot("31-launcher-error-alert")
        launcherAlert.buttons["OK"].tap()
    }

    // MARK: the shelf and what hangs off it

    /// 01-import-banner, 02-shelf, 03-tile-menu. The banner is the one an
    /// import ends with; here it reports the adoption of three loose files
    /// the script drops into the app's Documents first (an add-on WAD, a
    /// DeHackEd patch and a file that is not a WAD), which makes the longest
    /// text the banner has. It stays six seconds, so it is shot first.
    @MainActor
    func testD_Shelf() throws {
        // The script writes them: the app's container moves when xcodebuild
        // installs the app for the session, so only the host knows where it is.
        ask("loose-files", timeout: 30)
        let app = launch()
        defer { app.terminate() }
        if waitFor(app.descendants(matching: .any).matching(identifier: "importNoticeBanner").firstMatch,
                   "the import banner", timeout: 40) {
            shoot("01-import-banner", settle: 0.4)
        }
        guard waitFor(app.buttons["importButton"], "the shelf") else { return }
        Thread.sleep(forTimeInterval: 7)  // the banner leaves
        shoot("02-shelf")

        let tile = app.buttons["playFreedoom1"]
        guard bringIntoView(tile, in: app, drags: 40) else {
            XCTFail("[\(pose)] the Freedoom Phase 1 tile could not be reached"); return
        }
        longPress(tile)
        if waitFor(app.buttons["Details"], "the tile's long-press menu", timeout: 8) {
            shoot("03-tile-menu")
        }
    }

    /// 04 to 07: an imported game's page, its lower half, the rename prompt
    /// with the keyboard up, and the delete confirmation.
    ///
    /// `WADDLE_OPEN_PANEL` opens the page in the panel where the window has
    /// one (the open Duo held so its window is wide). Everywhere else it does
    /// nothing and the page is reached the way a player reaches it.
    @MainActor
    func testE_GamePage() throws {
        let app = launch(env: ["WADDLE_OPEN_PANEL": moddedGame])
        defer { app.terminate() }
        guard waitFor(app.buttons["importButton"], "the shelf", timeout: 30) else { return }
        let page = app.descendants(matching: .any).matching(identifier: "gamePage").firstMatch
        if !page.waitForExistence(timeout: 4) {
            let tile = app.buttons["game-\(moddedGame)"]
            guard bringIntoView(tile, in: app, drags: 40) else {
                XCTFail("[\(pose)] the \(moddedGame) tile is not on the shelf"); return
            }
            longPress(tile)
            guard waitFor(app.buttons["Details"], "the tile's long-press menu", timeout: 8) else { return }
            app.buttons["Details"].tap()
        }
        guard waitFor(page, "the game page") else { return }
        shoot("04-game-page")

        let name = app.buttons["gameNameButton"]
        if waitFor(name, "the page's title button", timeout: 5) {
            name.tap()
            let field = renameField(in: app)
            if waitFor(field, "the rename prompt", timeout: 8) {
                _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
                shoot("06-rename-prompt-keyboard", settle: 2.5)
                app.alerts.buttons["Cancel"].firstMatch.tap()
                Thread.sleep(forTimeInterval: 1)
            }
        }

        let delete = app.buttons["deleteGameButton"]
        guard bringIntoView(delete, in: app, scrolling: page) else {
            XCTFail("[\(pose)] could not scroll the game page to its last row"); return
        }
        shoot("05-game-page-lower")
        delete.tap()
        if waitFor(app.buttons.matching(identifier: "deleteGameAndSavesAction").firstMatch,
                   "the delete confirmation", timeout: 8) {
            shoot("07-delete-confirmation")
        }
    }

    // MARK: Settings

    /// Opens Settings: the gear, or the panel where the window has one.
    @MainActor
    private func openSettings() -> XCUIApplication? {
        let app = launch()
        guard waitFor(app.buttons["touchSchemeMenu"], "the shelf's gear", timeout: 30) else {
            app.terminate(); return nil
        }
        app.buttons["touchSchemeMenu"].tap()
        // By its first row: at the largest text sizes every later row is
        // below the fold of a lazy list, and so not in the hierarchy at all.
        guard waitFor(app.descendants(matching: .any).matching(identifier: "touchSchemePicker").firstMatch,
                      "Settings") else { app.terminate(); return nil }
        return app
    }

    /// The scrolling list that is Settings, as a sheet or in the panel. The
    /// shelf's own grid is a collection view too, so the list is found by
    /// its first row.
    @MainActor
    private func settingsList(_ app: XCUIApplication) -> XCUIElement {
        app.collectionViews.containing(.any, identifier: "touchSchemePicker").firstMatch
    }

    /// One Settings sub-screen per launch: open Settings, bring the row into
    /// reach, tap it, wait for `landmark`, shoot.
    @MainActor
    private func settingsScreen(row: String, shot: String, landmark: (XCUIApplication) -> XCUIElement) {
        guard let app = openSettings() else { return }
        defer { app.terminate() }
        let button = app.buttons[row]
        guard bringIntoView(button, in: app, scrolling: settingsList(app)) else {
            XCTFail("[\(pose)] Settings row \(row) could not be reached"); return
        }
        button.tap()
        guard waitFor(landmark(app), "the screen behind \(row)") else { return }
        shoot(shot)
    }

    /// 10-settings and 11-settings-lower.
    @MainActor
    func testF_Settings() throws {
        guard let app = openSettings() else { return }
        defer { app.terminate() }
        shoot("10-settings")
        // Only where Settings is taller than the window.
        if bringIntoView(app.buttons["aboutButton"], in: app, scrolling: settingsList(app)), dragsMade > 0 {
            shoot("11-settings-lower")
        }
    }

    @MainActor
    func testG_Files() throws {
        settingsScreen(row: "filesButton", shot: "12-files") {
            $0.descendants(matching: .any).matching(identifier: "filesScreen").firstMatch
        }
    }

    /// 13-hidden-games, with one game hidden so the screen has a row. The
    /// game is hidden from its tile's long-press menu.
    @MainActor
    func testH_HiddenGames() throws {
        let first = launch()
        let tile = first.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'game-' AND identifier CONTAINS 'Freedoom Phase 2'")).firstMatch
        if bringIntoView(tile, in: first, drags: 40) {
            longPress(tile)
            let hide = first.buttons["Hide from Shelf"]
            if hide.waitForExistence(timeout: 8) { hide.tap() }
            Thread.sleep(forTimeInterval: 1)
        }
        first.terminate()
        settingsScreen(row: "hiddenGamesButton", shot: "13-hidden-games") {
            $0.descendants(matching: .any).matching(identifier: "hiddenGamesScreen").firstMatch
        }
    }

    @MainActor
    func testI_About() throws {
        settingsScreen(row: "aboutButton", shot: "14-about") { $0.collectionViews["aboutView"] }
    }

    /// 15-control-feel, 16-control-feel-lower, 17-layout-editor.
    @MainActor
    func testJ_ControlFeel() throws {
        guard let app = openSettings() else { return }
        defer { app.terminate() }
        guard bringIntoView(app.buttons["controlFeelButton"], in: app, scrolling: settingsList(app)) else {
            XCTFail("[\(pose)] Settings row controlFeelButton could not be reached"); return
        }
        app.buttons["controlFeelButton"].tap()
        guard waitFor(app.buttons["controlFeelDoneButton"], "Control Feel") else { return }
        shoot("15-control-feel")
        let edit = app.buttons["editLayoutButton"]
        let form = app.collectionViews.containing(.button, identifier: "controlFeelDoneButton").firstMatch
        guard bringIntoView(edit, in: app, scrolling: form.exists ? form : nil) else {
            XCTFail("[\(pose)] Control Feel's Edit Layout row could not be reached"); return
        }
        if dragsMade > 0 { shoot("16-control-feel-lower") }
        edit.tap()
        if waitFor(app.buttons["layoutEditor.fireButton"], "the layout editor") {
            shoot("17-layout-editor")
        }
    }

    // MARK: import, and the shelf with a save

    /// 40-document-picker: the system's file picker over the shelf. The
    /// launch ends with it up; nothing is picked.
    @MainActor
    func testK_DocumentPicker() throws {
        let app = launch()
        defer { app.terminate() }
        guard waitFor(app.buttons["importButton"], "the shelf's Add button", timeout: 30) else { return }
        app.buttons["importButton"].tap()
        shoot("40-document-picker", settle: 5)
    }

    /// 50-shelf-continue-hero: the shelf once a game has a save. Runs after
    /// `testA_Session`, which is what makes Freedoom Phase 1 the game last
    /// played; `WADDLE_SEED_CONTINUE_SAVE` gives it the save.
    @MainActor
    func testL_ContinueHero() throws {
        let app = launch(env: ["WADDLE_SEED_CONTINUE_SAVE": "1"])
        defer { app.terminate() }
        guard waitFor(app.buttons["continueHero"], "the Continue hero", timeout: 30) else { return }
        shoot("50-shelf-continue-hero")
    }
}
