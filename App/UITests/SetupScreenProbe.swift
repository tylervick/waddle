import XCTest

/// One row of an engine setup screen, as `WoofIOS_DebugSetupState` reports
/// it on the overlay's `setupMenuProbe` element (issue #440). Rects are in
/// the app's points.
struct SetupProbeItem {
    /// T slider, O on/off, C choice, N number, I input binding, F opens a
    /// screen, R reset button, W weapon number, - title or other.
    let kind: Character
    /// The cursor cannot land on it (a title, a gap, a disabled row).
    let skip: Bool
    /// Where a press acts on it: the whole width of the screen for most
    /// rows, the slider itself for a slider.
    let press: CGRect
    /// What it draws: its label, its setting, its slider.
    let drawn: CGRect
    let value: Int

    /// The part of what it draws where a press acts on it. For most rows
    /// that is all of it; for a slider it is the slider, and the label to
    /// its left and the figure to its right are drawn but take no press
    /// anywhere, button or no button.
    var touchable: CGRect {
        let both = drawn.intersection(press)
        return both.isNull ? .zero : both
    }
}

struct SetupProbeState {
    let screen: Int
    let page: Int
    let cursor: Int
    let selecting: Bool
    let tabs: [CGRect]
    let items: [SetupProbeItem]

    /// Nil when no setup screen is up (`ss=-1`) or the text is not a state.
    init?(_ text: String) {
        var words: [String: String] = [:]
        for word in text.split(separator: " ") {
            let kv = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.count == 2 { words[String(kv[0])] = String(kv[1]) }
        }
        guard let screen = Int(words["ss"] ?? ""), screen >= 0,
              let page = Int(words["pg"] ?? ""), let cursor = Int(words["on"] ?? "") else { return nil }
        func rect(_ s: Substring) -> CGRect? {
            let n = s.split(separator: ",").compactMap { Double($0) }
            return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : nil
        }
        self.screen = screen
        self.page = page
        self.cursor = cursor
        self.selecting = words["sel"] == "1"
        self.tabs = (words["tabs"] ?? "").split(separator: "|").compactMap(rect)
        self.items = (words["items"] ?? "").split(separator: "|").compactMap { entry in
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 4, let kind = parts[0].first,
                  let press = rect(parts[1]), let drawn = rect(parts[2]),
                  let value = Int(parts[3]) else { return nil }
            return SetupProbeItem(kind: kind, skip: parts[0].dropFirst() == "x",
                                  press: press, drawn: drawn, value: value)
        }
    }
}

/// Where a rect meets one of the overlay's buttons.
struct SetupProbeHit {
    let button: String
    /// On the button's circle; otherwise only inside its near-miss cushion.
    let onButton: Bool
    /// The point of the rect nearest the button's centre.
    let point: CGPoint
}

extension XCUIApplication {
    /// The engine's setup screen now, or nil with none up.
    @MainActor
    func setupProbeState() -> SetupProbeState? {
        let probe = otherElements["setupMenuProbe"]
        guard probe.exists, let label = (try? probe.snapshot())?.label else { return nil }
        return SetupProbeState(label)
    }

    /// The overlay's buttons that are on screen with a menu up, by
    /// identifier. MAP is hidden in menus and is left out.
    @MainActor
    func overlayButtonFramesInMenus() -> [(id: String, frame: CGRect)] {
        ["useButton", "fireButton", "weaponPrevButton", "weaponNextButton", "menuButton"].compactMap {
            let button = buttons[$0]
            return button.exists ? ($0, button.frame) : nil
        }
    }
}

/// Every button `rect` runs under, or into the 20 pt cushion of
/// (`TouchTrackRouter.buttonNearMissMargin`). An empty rect meets nothing.
func setupProbeHits(_ rect: CGRect, buttons: [(id: String, frame: CGRect)]) -> [SetupProbeHit] {
    guard rect.width > 0, rect.height > 0 else { return [] }
    // A point well inside the rect. The engine tests a press in whole menu
    // units with exclusive edges, a unit is up to 3.3 points (an open iPhone
    // Duo), and the probe's figures are whole points: a point nearer an
    // edge than that is on the item or off it by rounding alone.
    let inner = rect.insetBy(dx: min(5, rect.width / 2), dy: min(5, rect.height / 2))
    return buttons.compactMap { button in
        let frame = button.frame
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        let nearest = CGPoint(x: min(max(centre.x, inner.minX), inner.maxX),
                              y: min(max(centre.y, inner.minY), inner.maxY))
        let radius = min(frame.width, frame.height) / 2
        if hypot(nearest.x - centre.x, nearest.y - centre.y) <= radius - 1 {
            return SetupProbeHit(button: button.id, onButton: true, point: nearest)
        }
        if frame.insetBy(dx: -19, dy: -19).contains(nearest) {
            return SetupProbeHit(button: button.id, onButton: false, point: nearest)
        }
        return nil
    }
}

/// Walks the engine's seven setup screens (Options > General, Key Bindings,
/// Compatibility, Status Bar/HUD, Automap, Weapons, Enemies), every tab of
/// each, for a test that wants to look at every row (issue #440).
///
/// The taps are the caller's, because on an open iPhone Duo a tap aimed by
/// coordinate has to be made by the host (`DuoLayoutSweepTests`).
@MainActor
struct SetupScreenWalker {
    let app: XCUIApplication
    let hud: XCUIElement
    let tap: (CGPoint) -> Void

    static let screenCount = 7

    /// `cm=` and `tgt=` of the debug HUD.
    func menu() -> (name: String, targets: [CGPoint]) {
        var name = "", targets: [CGPoint] = []
        let label = (try? hud.snapshot())?.label ?? ""
        for word in label.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            if word.hasPrefix("cm=") { name = String(word.dropFirst(3)) }
            if word.hasPrefix("tgt=") {
                targets = word.dropFirst(4).split(separator: "|").compactMap { pair in
                    let xy = pair.split(separator: ",").compactMap { Double($0) }
                    return xy.count == 2 ? CGPoint(x: xy[0], y: xy[1]) : nil
                }
            }
        }
        return (name, targets)
    }

    /// A whole-number field of the debug HUD: `mt` (pointer presses and
    /// releases the menu was sent) or `btn` (pad-button events the engine
    /// has processed).
    func hudNumber(_ key: String) -> Int? {
        let label = (try? hud.snapshot())?.label ?? ""
        for word in label.split(whereSeparator: { $0 == " " || $0 == "\n" }) where word.hasPrefix(key + "=") {
            return Int(word.dropFirst(key.count + 1))
        }
        return nil
    }

    func wait<T>(_ timeout: TimeInterval, for value: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let got = value() { return got }
            if Date() >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// ≡ until no menu is up. False if one would not leave.
    @discardableResult
    func closeMenus() -> Bool {
        for _ in 0..<4 {
            if wait(1.5, for: { menu().name == "off" ? true : nil }) != nil { return true }
            app.buttons["menuButton"].tap()
        }
        return wait(3, for: { menu().name == "off" ? true : nil }) != nil
    }

    /// The Options menu's seven items, from wherever the menu is.
    func openOptions() -> [CGPoint]? {
        for _ in 0..<5 {
            let now = menu()
            switch now.name {
            case "options" where now.targets.count >= Self.screenCount:
                return now.targets
            case "main" where now.targets.count >= 5:
                tap(now.targets[1]) // New Game, Options, ...
            case "off":
                app.buttons["menuButton"].tap()
            default:
                guard closeMenus() else { return nil }
            }
            Thread.sleep(forTimeInterval: 1.2) // the HUD's next refresh
        }
        let last = menu()
        return last.name == "options" && last.targets.count >= Self.screenCount ? last.targets : nil
    }

    /// Opens screen `index` of the Options menu at tab `tab` and returns
    /// what is on it once it has been drawn, or nil if it did not arrive.
    func open(screen index: Int, tab: Int) -> SetupProbeState? {
        if let now = app.setupProbeState(), !now.selecting, tab < max(1, now.tabs.count),
           let opened = Self.lastOpened, opened.index == index, opened.engineScreen == now.screen {
            return select(tab: tab, from: now)
        }
        guard closeMenus(), let options = openOptions() else { return nil }
        tap(options[index])
        guard let first = wait(8, for: { app.setupProbeState() }) else { return nil }
        Self.lastOpened = (index, first.screen)
        return select(tab: tab, from: first)
    }

    private func select(tab: Int, from state: SetupProbeState) -> SetupProbeState? {
        if state.page != tab {
            guard tab < state.tabs.count else { return nil }
            tap(CGPoint(x: state.tabs[tab].midX, y: state.tabs[tab].midY))
            guard wait(8, for: { () -> Bool? in app.setupProbeState()?.page == tab ? true : nil }) != nil else {
                return nil
            }
        }
        // A page's rows report what they drew, so give it a frame and the
        // probe a refresh (0.5 s).
        Thread.sleep(forTimeInterval: 1.2)
        return app.setupProbeState()
    }

    /// Which Options item the screen that is up was opened from, and the
    /// engine's own number for it (a different order; a row that opens a
    /// further screen changes it).
    private static var lastOpened: (index: Int, engineScreen: Int)?
}

/// One row that draws under a button, and what a touch there did.
struct SetupProbeFinding {
    let screen: Int
    let tab: Int
    let item: Int
    let kind: Character
    let hit: SetupProbeHit
    /// "value 0 -> 1", "nothing changed", "the menu closed", ...
    let outcome: String
    /// The touch went to the menu and acted on this row: the menu was sent
    /// a pointer press, and afterwards the cursor is on the row (or, for a
    /// row that opens a screen, the screen opened). A press that a button
    /// took, or that the button's cushion swallowed, sends the menu nothing.
    let actedOnRow: Bool
}

extension SetupScreenWalker {
    /// Looks at every row of every tab of the seven screens and prints it
    /// (`SETUP440 ...` lines, for the measurement issue #440 asked for).
    /// Where the touchable part of what a row DRAWS lies under a button or
    /// its cushion, and the cursor can land on the row, touches the row
    /// there and records what happened.
    /// Returns those findings; `unreached` names screens or tabs that did
    /// not open.
    func measure(pose: String) -> (findings: [SetupProbeFinding], rows: Int, unreached: [String], log: String) {
        var lines: [String] = []
        func print(_ line: String) { lines.append(line); Swift.print(line) }
        var findings: [SetupProbeFinding] = []
        var unreached: [String] = []
        var rows = 0
        let buttons = app.overlayButtonFramesInMenus()
        print("SETUP440 \(pose) window \(app.frame.size) buttons \(buttons.map { "\($0.id)=\(fmt($0.frame))" }.joined(separator: " "))")
        for screen in 0..<Self.screenCount {
            guard let first = open(screen: screen, tab: 0) else {
                unreached.append("screen \(screen)")
                continue
            }
            for tab in 0..<max(1, first.tabs.count) {
                guard let state = open(screen: screen, tab: tab) else {
                    unreached.append("screen \(screen) tab \(tab)")
                    continue
                }
                for (t, rect) in state.tabs.enumerated() {
                    for hit in setupProbeHits(rect, buttons: buttons) {
                        print("SETUP440 \(pose) s\(screen) TAB \(t) \(fmt(rect)) under \(hit.button) \(hit.onButton ? "on" : "cushion")")
                    }
                }
                for (index, item) in state.items.enumerated() {
                    rows += 1
                    let drawnHits = setupProbeHits(item.touchable, buttons: buttons)
                    let pressHits = setupProbeHits(item.press, buttons: buttons)
                    print("SETUP440 \(pose) s\(screen) t\(tab) i\(index) \(item.kind)\(item.skip ? "x" : "") v=\(item.value) drawn=\(fmt(item.drawn)) press=\(fmt(item.press))"
                          + " touchableUnder=[\(drawnHits.map { "\($0.button):\($0.onButton ? "on" : "cushion")" }.joined(separator: ","))]"
                          + " pressUnder=[\(pressHits.map { "\($0.button):\($0.onButton ? "on" : "cushion")" }.joined(separator: ","))]")
                    guard !item.skip else { continue }
                    for hit in drawnHits where hit.button != "menuButton" {
                        guard let before = open(screen: screen, tab: tab), index < before.items.count else {
                            unreached.append("screen \(screen) tab \(tab) before the touch on item \(index)")
                            continue
                        }
                        // Aim from the row as it is NOW: an earlier touch on
                        // this page may have changed its setting, and with
                        // it how far the row's text runs.
                        guard let hit = setupProbeHits(before.items[index].touchable, buttons: buttons)
                            .first(where: { $0.button == hit.button }) else {
                            print("SETUP440 \(pose) s\(screen) t\(tab) i\(index) no longer under \(hit.button) (now \(fmt(before.items[index].touchable)))")
                            continue
                        }
                        let pressesBefore = hudNumber("mt") ?? 0
                        tap(hit.point)
                        Thread.sleep(forTimeInterval: 1.5)
                        let after = app.setupProbeState()
                        let pressed = (hudNumber("mt") ?? 0) > pressesBefore
                        let (outcome, acted) = describe(before: before, after: after, item: index, menuPressed: pressed)
                        print("SETUP440 \(pose) s\(screen) t\(tab) i\(index) TOUCH (\(Int(hit.point.x)),\(Int(hit.point.y))) \(hit.button) \(hit.onButton ? "on" : "cushion"): \(outcome)")
                        findings.append(SetupProbeFinding(screen: screen, tab: tab, item: index, kind: item.kind,
                                                          hit: hit, outcome: outcome, actedOnRow: acted))
                        // Leave whatever the touch started (a choice being
                        // changed, a key being bound) before the next row.
                        if after == nil || after?.selecting == true || after?.screen != before.screen
                            || after?.page != before.page {
                            closeMenus()
                        }
                    }
                }
            }
        }
        closeMenus()
        print("SETUP440 \(pose) done rows=\(rows) findings=\(findings.count) unreached=\(unreached)")
        return (findings, rows, unreached, lines.joined(separator: "\n"))
    }

    private func describe(before: SetupProbeState, after: SetupProbeState?, item: Int,
                          menuPressed: Bool) -> (String, Bool) {
        let who = menuPressed ? "the menu took the press" : "the menu was sent no press"
        guard let after else { return ("\(who); the menu closed (now '\(menu().name)')", false) }
        if after.screen != before.screen {
            return ("\(who); another screen opened (ss \(before.screen) -> \(after.screen))",
                    menuPressed && before.items[item].kind == "F")
        }
        if after.page != before.page { return ("\(who); the tab changed (\(before.page) -> \(after.page))", false) }
        var parts = [who]
        for (i, (a, b)) in zip(before.items, after.items).enumerated() where a.value != b.value {
            parts.append("item \(i) value \(a.value) -> \(b.value)")
        }
        if after.cursor != before.cursor { parts.append("cursor \(before.cursor) -> \(after.cursor)") }
        if after.selecting != before.selecting { parts.append("selecting \(before.selecting) -> \(after.selecting)") }
        return (parts.joined(separator: "; "), menuPressed && after.cursor == item)
    }

    private func fmt(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
    }
}
