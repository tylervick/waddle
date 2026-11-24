import XCTest
import notify

extension XCTestCase {
    /// Taps a text field, clears any existing contents, and types `text`.
    /// Shared by the preset-creation / edit / RealWAD UI flows.
    ///
    /// Taps the trailing edge so the caret lands at the end before
    /// backspacing — a centre tap lands mid-string in a narrow alert field.
    func clearAndType(_ field: XCUIElement, _ text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        if let existing = field.value as? String, !existing.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(text)
        waitForAlertToSettle()
    }

    /// Waits until the keyboard is back on screen and the alert that holds
    /// its focus has moved clear of it, so the next tap is aimed at where the
    /// alert's buttons are rather than where they were.
    ///
    /// On the iOS 27 simulator, `typeText` into an alert's text field hides
    /// the software keyboard while it types -- its frame sits entirely below
    /// the screen (y = 918 on an 874 pt display) -- and the alert drops to
    /// the centre. About 400 ms after the last key the keyboard slides back
    /// (y = 590) and the alert springs up to its keyboard-avoiding position.
    /// A tap issued straight after `typeText` is aimed at the centred frame
    /// and lands below the alert once it has moved: nothing is hit, the alert
    /// stays up with the typed text, and the test taps through it (issue
    /// #306; iOS 26.2 on CI does not do this). The keyboard *element* exists
    /// throughout, so "is there a keyboard" is not the condition; "is its
    /// frame on screen, and is the alert clear of it" is. See
    /// docs/learnings/ios27-alert-moves-under-typetext.md.
    ///
    /// Once the resting condition holds, the alert's frame also has to read
    /// the same three samples running (the probes only ever saw the two
    /// discrete positions, so this is insurance against an in-flight frame,
    /// at the cost of 200 ms).
    ///
    /// `timeout` is how long the alert is given to come to rest, and it is
    /// judged by when a sample was begun, not by when the loop gets round to
    /// looking at the clock. It used to bound the whole loop, which made it
    /// a guess about the runner: one sample is four accessibility queries,
    /// 0.19 s locally and 1.8 s on a slow CI runner, so three samples of a
    /// settled alert did not fit in 3 s there and the helper failed an alert
    /// that had come to rest (issue #384). Now a sample fails the wait only
    /// if it was begun after the timeout and still did not add to the run of
    /// matching samples: the alert was seen unsettled that long after the
    /// typing ended. A run that is still growing is left to finish, which is
    /// at most three more samples, so the wait is bounded either way. A
    /// failure is reported here, by name, rather than letting the next tap
    /// fail somewhere less legible.
    func waitForAlertToSettle(timeout: TimeInterval = 3,
                              file: StaticString = #filePath, line: UInt = #line) {
        let app = XCUIApplication()
        let alert = app.alerts.firstMatch
        guard alert.exists else { return }
        let start = Date()
        var previousAlertFrame: CGRect?
        var stableSamples = 0
        while true {
            let begun = Date().timeIntervalSince(start)
            let keyboard = app.keyboards.firstMatch
            guard keyboard.exists else { return }
            let keyboardFrame = keyboard.frame
            let alertFrame = alert.frame
            let onScreen = keyboardFrame.minY < app.frame.maxY
            let runBefore = stableSamples
            if onScreen && !alertFrame.intersects(keyboardFrame) {
                stableSamples = alertFrame == previousAlertFrame ? stableSamples + 1 : 1
                if stableSamples >= 3 { return }
            } else {
                stableSamples = 0
            }
            if begun >= timeout && stableSamples <= runBefore {
                XCTFail("the alert did not settle clear of the keyboard within \(timeout)s " +
                        "(alert \(alertFrame), keyboard \(keyboardFrame), " +
                        String(format: "sampled %.1fs in)", begun),
                        file: file, line: line)
                return
            }
            previousAlertFrame = alertFrame
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Opens a tile's game page via its long-press menu (spec §3.1).
    func openGamePage(_ app: XCUIApplication, tile tileID: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        let tile = app.buttons[tileID]
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "tile \(tileID) missing", file: file, line: line)
        tile.press(forDuration: 1.0)
        app.buttons["Details"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "gamePage").firstMatch
            .waitForExistence(timeout: 5), "game page never appeared", file: file, line: line)
    }

    /// Pops the game page back to the shelf. Asserts, so a broken pop fails
    /// here rather than as a timeout against the wrong screen later.
    ///
    /// Found by UIKit's own `BackButton` identifier, not by its title and not
    /// inside a navigation bar (issue #352): on a closed iPhone Duo the system
    /// lays the button out in the status column, where it has no label and
    /// sits in a toolbar, so a query for a navigation-bar button titled
    /// "Waddle" found nothing while the button was on screen.
    func returnToShelf(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.buttons.matching(identifier: "BackButton").firstMatch
        // Where the window is wide enough for it (an open iPhone Duo held
        // upright), the page is not pushed at all: it is a column beside the
        // shelf, closed by its own Done button, and there is no back button
        // to find (issue #409). Only when there is none is Done looked for.
        let panelDone = app.buttons["Done"].firstMatch
        if !back.waitForExistence(timeout: 5), panelDone.exists {
            panelDone.tap()
        } else {
            XCTAssertTrue(back.exists, "no back button — navigation is broken", file: file, line: line)
            back.tap()
        }
        XCTAssertTrue(app.buttons["importButton"].waitForExistence(timeout: 10),
                      "left the page but never landed back on the shelf", file: file, line: line)
    }

    /// Opens Settings → Files (spec §3.3).
    func openFiles(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let gear = app.buttons["touchSchemeMenu"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "gear missing", file: file, line: line)
        gear.tap()
        let files = app.buttons["filesButton"]
        XCTAssertTrue(files.waitForExistence(timeout: 5), "Files row missing from Settings", file: file, line: line)
        files.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "filesScreen").firstMatch
            .waitForExistence(timeout: 5), "Files screen never appeared", file: file, line: line)
    }

    /// Closes Settings (from Files or its root) back to the shelf.
    ///
    /// The back button is addressed through its OWN navigation bar, not through
    /// `app.navigationBars`. Settings is a sheet, so the shelf underneath stays
    /// in the accessibility tree, and its gear is `Label("Settings", ...)` --
    /// an unscoped query matches both that and the Files back button (which iOS
    /// labels with its parent's title, also "Settings") and raises "Multiple
    /// matching elements found". Same scoping HiddenGamesScreenTests uses.
    /// See docs/learnings/sheet-leaves-presenter-navbar-in-the-tree.md.
    ///
    /// On a closed iPhone Duo that button is not there to find: the system
    /// moves it to the status column, in a toolbar, with the identifier
    /// `BackButton` and no label (the same layout `returnToShelf` meets,
    /// issue #352), so the titled query came up empty, nothing was tapped, and
    /// the Done assertion below failed on the Files screen (issue #409's first
    /// Duo capture). The shelf under the sheet is a navigation root and has no
    /// back button of its own, so the bare identifier is unambiguous here.
    func closeSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.navigationBars["Files"].buttons["Settings"]
        let unlabelledBack = app.buttons.matching(identifier: "BackButton").firstMatch
        if back.waitForExistence(timeout: 2) {
            back.tap()
        } else if unlabelledBack.exists {
            unlabelledBack.tap()
        }
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Settings Done missing", file: file, line: line)
        done.tap()
        XCTAssertTrue(app.buttons["importButton"].waitForExistence(timeout: 10), file: file, line: line)
    }

    /// Scrolls until `element` can be tapped. A lazy `Form`/`List` omits
    /// off-screen rows entirely (docs/learnings/lazy-form-hides-rows-from-uitests.md),
    /// but a row can also be in the accessibility tree and still hang off the
    /// window's bottom edge: on a closed iPhone Duo (678 pt tall) the game
    /// page's scheme picker existed at y 668 to 702, the old "swipe while it
    /// does not exist" loop never swiped, and the tap opened nothing
    /// (issue #352).
    ///
    /// `isHittable` alone does not catch that. It answered true for that
    /// row: XCUITest picks a hit point inside whatever sliver is visible, and
    /// a tap on ten points of row at the very bottom edge does not open its
    /// menu. So the element must also lie wholly inside the window.
    ///
    /// `container` is what gets swiped; nil swipes the app, which starts
    /// from the window's centre. That is only right where one scroll view
    /// fills the window. On an iPad the game page is a side panel at the
    /// window's right, the centre is on the shelf, and swiping the app
    /// scrolled the shelf while the row stayed below the panel's fold
    /// (issue #519). Pass the scroll view that holds `element`.
    func scrollTo(_ element: XCUIElement, in app: XCUIApplication, swiping container: XCUIElement? = nil,
                  maxSwipes: Int = 6, file: StaticString = #filePath, line: UInt = #line) {
        var swipes = 0
        while !isFullyOnScreen(element, in: app) && swipes < maxSwipes {
            (container ?? app).swipeUp()
            swipes += 1
        }
        XCTAssertTrue(element.waitForExistence(timeout: 2), "\(element) never scrolled into view", file: file, line: line)
    }

    /// Whether a tap on `element` lands on the element proper: it exists, is
    /// hittable, and its whole frame is inside the app's window.
    private func isFullyOnScreen(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable else { return false }
        return app.windows.firstMatch.frame.contains(element.frame)
    }

    /// `element`'s label from a single accessibility snapshot, or nil when
    /// the element is not there.
    ///
    /// `element.exists` followed by `element.label` is two snapshots. An
    /// element that leaves between them (the debug HUD goes with the engine
    /// session) has already answered "exists", and the `label` read then
    /// records a test failure rather than returning anything (issue #350).
    /// `snapshot()` throws instead, so one `try?` covers both the element
    /// that was never there and the one that left mid-read.
    ///
    /// `@MainActor` because `snapshot()` is, and its result is not Sendable:
    /// only the label, a String, leaves this method.
    @MainActor
    func labelIfPresent(_ element: XCUIElement) -> String? {
        (try? element.snapshot())?.label
    }

    /// Tells the app that this test's steps inside the running session are
    /// done, so a held autoquit may end it (issue #380).
    ///
    /// `WADDLE_AUTOQUIT_SECONDS` asks a session to quit a fixed number of
    /// seconds after it starts. On a slow CI runner one tap can take nine
    /// seconds, the budget runs out in the middle of the test's steps, and
    /// the next step fails on a control that left with the session. A launch
    /// made with `holdAutoquit()` keeps the same budget but does not act on
    /// it until this is called: the session lasts its budget or as long as
    /// the test needs, whichever is longer. On a fast machine that is the
    /// budget, to the second, so tests that measure it are undisturbed.
    ///
    /// Call it after the last step that needs the session, while the session
    /// is known to be up (an overlay element has been seen): the app drops a
    /// release that arrives with no session running. A test that never calls
    /// it leaves the session running until the next launch replaces the app,
    /// which is right for a test that does not wait for the session to end.
    ///
    /// The name is `EngineSession.autoquitReleaseNotification`, spelled out
    /// because this target cannot import the app.
    func releaseAutoquit() {
        notify_post("com.tylervick.waddle.test.autoquit-release")
    }

    /// Dismisses iOS's one-time "Slide to Type" introduction if it is
    /// covering the system keyboard, so a tap aimed at a key reaches it.
    /// Call it once the keyboard is up and before tapping a key; when there
    /// is no panel it does nothing.
    ///
    /// The first keyboard a newly created simulator shows carries this panel
    /// ("Speed up your typing by sliding your finger across the letters...",
    /// `Continue`) in its own window above the keys. The keys stay in the
    /// accessibility tree underneath it, so `waitForExistence` on a key
    /// succeeds and the tap then lands on the panel instead (issue #511).
    /// `typeText` is not affected. The panel is found by its view's
    /// identifier, not by the word "Continue", which the launcher behind the
    /// game also uses. See
    /// docs/learnings/new-simulator-keyboard-shows-slide-to-type-tutorial.md.
    ///
    /// `timeout` is how long the panel is given to appear after the keyboard
    /// has; it came up with the keys in every run seen, so this is only
    /// insurance against it trailing them.
    func dismissSlideToTypeIntroduction(in app: XCUIApplication, timeout: TimeInterval = 1,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let intro = app.otherElements["UIContinuousPathIntroductionView"]
        guard intro.waitForExistence(timeout: timeout) else { return }
        let proceed = intro.buttons.firstMatch
        XCTAssertTrue(proceed.waitForExistence(timeout: 2),
                      "the Slide to Type introduction has no button to dismiss it",
                      file: file, line: line)
        proceed.tap()
        XCTAssertTrue(intro.waitForNonExistence(timeout: 5),
                      "the Slide to Type introduction stayed over the keyboard after Continue",
                      file: file, line: line)
    }

    /// The Rename alert's text field. SwiftUI does not forward an
    /// `accessibilityIdentifier` set on an alert's `TextField`, so it is found
    /// through the alert itself.
    func renameField(in app: XCUIApplication) -> XCUIElement {
        app.alerts["Rename"].textFields.firstMatch
    }
}

/// A point on a slot of the engine's save list that lies under one of the
/// overlay's buttons, or inside a button's near-miss cushion (issue #430).
struct SaveSlotAim {
    let point: CGPoint
    /// "slot 7 at (485, 323), on useButton", for a failure message.
    let what: String
}

extension XCUIApplication {
    /// Every (button, slot) pair of the save list on screen where the slot's
    /// frame runs under the button's circle or its 20 pt cushion
    /// (`TouchTrackRouter.buttonNearMissMargin`): the point at the button's
    /// own x where the slot reaches that far, at the slot's nearest end where
    /// it does not. `slots` and `slotWidth` are the debug HUD's `tgt=` and
    /// `iw=` with the save list up. `measured` is what was compared, for the
    /// message of a run that found nothing. Element frames are in the app's
    /// points in every pose of an iPhone Duo, so this holds on an open one.
    @MainActor
    func saveSlotAimsUnderButtons(slots: [CGPoint], slotWidth: CGFloat) -> (aims: [SaveSlotAim], measured: String) {
        var aims: [SaveSlotAim] = []
        var measured = ["slots \(slots.map { "(\(Int($0.x)), \(Int($0.y)))" }) width \(Int(slotWidth))"]
        for id in ["useButton", "fireButton", "weaponPrevButton", "weaponNextButton"] {
            let frame = buttons[id].frame
            measured.append("\(id) \(frame)")
            let radius = min(frame.width, frame.height) / 2
            for (index, slot) in slots.enumerated() {
                // 4 pt inside the slot's ends: the rect's edges are exclusive
                // and the HUD's figures are whole points.
                let x = min(max(frame.midX, slot.x - slotWidth / 2 + 4), slot.x + slotWidth / 2 - 4)
                let point = CGPoint(x: x.rounded(), y: slot.y)
                let onButton = hypot(point.x - frame.midX, point.y - frame.midY) <= radius - 2
                let inCushion = frame.insetBy(dx: -18, dy: -18).contains(point)
                guard onButton || inCushion else { continue }
                aims.append(SaveSlotAim(point: point, what:
                    "slot \(index + 1) at (\(Int(point.x)), \(Int(point.y))), "
                    + (onButton ? "on \(id)" : "in \(id)'s near-miss cushion")))
            }
        }
        return (aims, measured.joined(separator: "; "))
    }

    /// Makes this launch install Freedoom Phase 1 and Phase 2 as imported
    /// files, with their base games, from this runner's own copies
    /// (`WADDLE_TEST_FREEDOOM_DIR`, issue #504). The app then skips its
    /// bundled seeder, so the shelf's Freedoom tiles (`playFreedoom1`,
    /// `playFreedoom2`) come from here and not from the app's GameData/,
    /// which #505 removes. Set it beside `WADDLE_RESET_STORE`, before
    /// `launch()`, on every launch of a test that needs Freedoom: a launch
    /// without it seeds from the bundle again.
    ///
    /// The path is the .xctest bundle inside the runner's container. On the
    /// simulator the app process reads it directly; nothing here runs on a
    /// device.
    func provideFreedoom() {
        launchEnvironment["WADDLE_TEST_FREEDOOM_DIR"] = Self.freedoomDirectory
    }

    private static let freedoomDirectory: String = {
        let bundle = Bundle(for: FreedoomBundleAnchor.self)
        guard let url = bundle.url(forResource: "freedoom1", withExtension: "wad"),
              bundle.url(forResource: "freedoom2", withExtension: "wad") != nil else {
            preconditionFailure("WaddleUITests carries no freedoom1.wad/freedoom2.wad; " +
                                "run `mise run bootstrap` (fetch-freedoom) and `mise run generate`")
        }
        return url.deletingLastPathComponent().path
    }()

    /// Makes this launch's autoquit wait for `XCTestCase.releaseAutoquit()`.
    /// For every test that does something inside a live session; set it
    /// beside `WADDLE_AUTOQUIT_SECONDS`, before `launch()`.
    func holdAutoquit() {
        launchEnvironment["WADDLE_AUTOQUIT_HOLD"] = "1"
    }
}

/// Names this test bundle for `Bundle(for:)` in `provideFreedoom()`.
private final class FreedoomBundleAnchor {}
