import XCTest

/// Regression test for issue #266: engine state a session inherited from the
/// one before it in the same process.
///
/// `WoofIOS_DebugSessionStartState()` captures, at the start of each
/// session's game loop (the point `GlobalsDiffProbeTests`' diff is taken),
/// the values the writable-globals diff found leaking: `fast_exit`,
/// `D_Display`'s memory of the previous frame, `demoloop_prev`, the
/// autoload directory list, the DSDHacked table sizes, the colorized
/// message table, the status-bar face patches and the music state. The
/// app shows it after the session ends (`WADDLE_DEBUG_SESSION_START`, see
/// ContentView).
///
/// Phase 1, Phase 2, Phase 2, Phase 1: at 16 s, Phase 1's short title page
/// ends inside a demo level, so session 2 follows a quit mid-level; Phase 2's
/// eleven-second title page does not, so session 3 follows a quit at the
/// title. Session 4 is Phase 1 again after another game's DEHACKED.
final class SessionStartStateTests: XCTestCase {

    private var autoquitSeconds = 16.0

    @MainActor
    func testEverySessionStartsFromTheSameState() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launchEnvironment["WADDLE_DEBUG_SESSION_START"] = "1"
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }

        let phase1 = app.buttons["playFreedoom1"]
        let phase2 = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'game-' AND identifier CONTAINS 'Freedoom Phase 2'"))
            .firstMatch

        let phase1Fresh = play(app, tile: phase1, name: "s1-phase1-fresh")
        let entry1 = label(app, "sessionEntryStateLabel", name: "s1")
        let phase2First = play(app, tile: phase2, name: "s2-phase2-first")
        let entry2 = label(app, "sessionEntryStateLabel", name: "s2")
        let phase2Second = play(app, tile: phase2, name: "s3-phase2-second")
        let entry3 = label(app, "sessionEntryStateLabel", name: "s3")
        let phase1Again = play(app, tile: phase1, name: "s4-phase1-again")
        let entry4 = label(app, "sessionEntryStateLabel", name: "s4")

        // Issue #268: what each session is handed before D_DoomMain must be
        // what a fresh process hands the first one, whatever ran before.
        for (name, entry) in [("session 1", entry1), ("session 2", entry2),
                              ("session 3", entry3), ("session 4", entry4)] {
            assertSameFields(entry ?? "", Self.freshEntry,
                             "\(name) was handed state from an earlier session")
        }

        // Every session must report, or a comparison below could pass on two
        // empty strings without testing anything.
        for (name, state) in [("session 1", phase1Fresh), ("session 2", phase2First),
                              ("session 3", phase2Second), ("session 4", phase1Again)] {
            XCTAssertFalse(state.isEmpty, "\(name) reported no session-start state")
        }

        // Game-independent: what upstream's one run per process starts with.
        // wipe=3/-1 is GS_DEMOSCREEN / wipe_Invalid, oldgs=-1 is GS_NONE.
        // music=1: the title page started its track. arenas=352 is the five
        // playsim arenas' reservation in MB, and compdb=40 woof.pk3's COMPDB
        // records: both grew by that much per session until issue #269.
        let pristine = ["exit": "0", "wipe": "3/-1", "oldgs": "-1", "view": "0", "demoprev": "0",
                        "music": "1", "arenas": "352", "compdb": "40"]
        for (name, state) in [("session 1", phase1Fresh), ("session 2", phase2First),
                              ("session 3", phase2Second), ("session 4", phase1Again)] {
            let fields = Self.fields(state)
            for (key, value) in pristine {
                XCTAssertEqual(fields[key], value,
                               "\(name) started with \(key)=\(fields[key] ?? "nil"), not \(value): \(state)")
            }
        }

        // Game-dependent: the same game must start the same way, whatever ran
        // before it in the process.
        assertSameFields(phase2Second, phase2First,
                         "second Phase 2 session did not start like the first")
        assertSameFields(phase1Again, phase1Fresh,
                         "Phase 1 after two Phase 2 sessions did not start like a fresh one")
    }

    /// A session that quits on the title page leaves its title track as
    /// `mus_playing`; the next session of the same game asked for that track,
    /// was told it was already playing, and opened in silence. Eight seconds
    /// is inside Phase 2's eleven-second title page.
    @MainActor
    func testTitleMusicStartsAfterAQuitAtTheTitle() throws {
        autoquitSeconds = 8.0
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launchEnvironment["WADDLE_DEBUG_SESSION_START"] = "1"
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }

        let phase2 = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'game-' AND identifier CONTAINS 'Freedoom Phase 2'"))
            .firstMatch
        let first = play(app, tile: phase2, name: "t1-phase2-quit-at-title")
        let firstZone = zoneKB(app, name: "t1")
        let second = play(app, tile: phase2, name: "t2-phase2-after-title-quit")
        let secondZone = zoneKB(app, name: "t2")

        XCTAssertEqual(Self.fields(first)["music"], "1",
                       "first session's title page started no music: \(first)")
        XCTAssertEqual(Self.fields(second)["music"], "1",
                       "session after a quit at the title started no music: \(second)")

        // Issue #269: module-owned PU_STATIC memory (no owner pointer, so not
        // cached lumps) must not grow from one session to the next. Title-only
        // sessions touch none of the grow-only render buffers, so what is left
        // is the lump cache's own array (about 29 KB per session with
        // Freedoom). Before the renderer freed its previous tables, each
        // session added about 1.4 MB.
        guard let a = firstZone, let b = secondZone else {
            return XCTFail("no zowned=<KB> from sessionStartZoneLabel (missing or unparseable; see the attachments)")
        }
        XCTAssertLessThan(b - a, 256,
            "module-owned zone memory grew by \(b - a) KB between two title-only sessions (\(a) -> \(b))")
    }

    /// Review of #276: R_InitTextures now frees the previous session's texture
    /// tables, so a session that died in I_Error part-way through them must
    /// not leave the next one freeing uninitialised or already-freed slots.
    /// WADDLE_DEBUG_FAIL_TEXTURES (r_data.c) makes session 1 fail at texture
    /// 100, after the tables exist but before most slots are filled, and
    /// session 3 fail before the tables are allocated at all. MallocScribble
    /// fills fresh allocations with 0xAA, so an unfilled slot is garbage
    /// rather than whatever zeros the allocator happened to hand back.
    @MainActor
    func testTextureInitFailureDoesNotBreakTheNextSession() throws {
        autoquitSeconds = 8.0
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launchEnvironment["WADDLE_DEBUG_FAIL_TEXTURES"] = "1:100,3:-1"
        app.launchEnvironment["MallocScribble"] = "1"
        app.launchEnvironment["WADDLE_TEST_NOGUI"] = "1"
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }

        let phase2 = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'game-' AND identifier CONTAINS 'Freedoom Phase 2'"))
            .firstMatch

        failInit(app, tile: phase2, name: "f1-fails-at-texture-100")
        _ = play(app, tile: phase2, name: "f2-after-a-partial-init")
        failInit(app, tile: phase2, name: "f3-fails-before-the-tables")
        _ = play(app, tile: phase2, name: "f4-after-a-failure-before-the-tables")
    }

    /// Starts a session that WADDLE_DEBUG_FAIL_TEXTURES makes fail, dismisses
    /// whatever error dialogs it raises, and checks it did fail.
    private func failInit(_ app: XCUIApplication, tile: XCUIElement, name: String,
                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "\(name): tile missing",
                      file: file, line: line)
        let exitLabel = app.staticTexts["engineExitLabel"]
        tile.tap()
        // The session fails during init, too fast for the previous exit label
        // to be seen clearing; the launcher's alert is the signal that it has
        // returned (WADDLE_TEST_NOGUI keeps SDL's own message box away).
        let alert = app.alerts["Couldn't run this game"]
        XCTAssertTrue(alert.waitForExistence(timeout: 60),
                      "\(name): no engine error alert; did the injected texture failure fire?",
                      file: file, line: line)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(
            format: "label CONTAINS 'WADDLE_DEBUG_FAIL_TEXTURES'")).firstMatch.exists,
            "\(name): the engine failed, but not where the test made it fail", file: file, line: line)
        alert.buttons["OK"].tap()
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 10),
                      "\(name): no exit label after the failure", file: file, line: line)
        XCTAssertNotEqual(exitLabel.label, "Engine exited: 0",
                          "\(name): the session did not fail", file: file, line: line)
    }

    /// `zowned=<KB>` from the label shown next to the session-start string.
    private func zoneKB(_ app: XCUIApplication, name: String) -> Int? {
        let label = app.staticTexts["sessionStartZoneLabel"]
        guard label.waitForExistence(timeout: 5) else { return nil }
        let attachment = XCTAttachment(string: label.label)
        attachment.name = "\(name)-session-start-zone"
        attachment.lifetime = .keepAlways
        add(attachment)
        return Self.fields(label.label)["zowned"].flatMap(Int.init)
    }

    /// What a fresh process hands its first session (WoofIOS_DebugSessionEntryState).
    static let freshEntry = "amlvl=-1/-1 amstop=1 amdef=0 amcol=1 msg=0/0 sbar=0 rewind=0 "
        + "pad=0 rumble=0 tex=0 cmap=0 skipbl=0"

    /// Issue #268: AM_Start re-initialised the automap only when the map
    /// number changed, so after Phase 2's MAP01 the automap of Phase 1's E1M1
    /// (also episode 1, map 1) kept MAP01's bounds and zoom limits. Warps
    /// straight into map 1 of each game and opens the automap in each.
    @MainActor
    func testAutomapBoundsAreEachMapsOwn() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launchEnvironment["WADDLE_DEBUG_SESSION_START"] = "1"
        app.launchEnvironment["WADDLE_TEST_WARP"] = "1"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }

        let phase1 = app.buttons["playFreedoom1"]
        let phase2 = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'game-' AND identifier CONTAINS 'Freedoom Phase 2'"))
            .firstMatch

        var bounds: [String?] = []
        var entries: [String?] = []
        for (tile, name) in [(phase1, "a1-phase1-e1m1"), (phase2, "a2-phase2-map01"),
                             (phase1, "a3-phase1-e1m1-again")] {
            _ = play(app, tile: tile, name: name) {
                let map = app.buttons["automapButton"]
                XCTAssertTrue(map.waitForExistence(timeout: 30), "\(name): no automap button")
                Thread.sleep(forTimeInterval: 4)
                map.tap()
            }
            bounds.append(label(app, "automapBoundsLabel", name: name))
            entries.append(label(app, "sessionEntryStateLabel", name: name))
        }

        for (i, entry) in entries.enumerated() {
            assertSameFields(entry ?? "", Self.freshEntry,
                             "session \(i + 1) was handed state from an earlier session")
        }
        // Every session must report, or the comparisons below could pass on
        // nil == nil without the automap having opened at all.
        let e1m1 = try XCTUnwrap(bounds[0], "no automapBoundsLabel after the first E1M1 session")
        let map01 = try XCTUnwrap(bounds[1], "no automapBoundsLabel after the MAP01 session")
        let e1m1Again = try XCTUnwrap(bounds[2], "no automapBoundsLabel after the second E1M1 session")
        // The automap really opened on two different maps...
        XCTAssertNotEqual(e1m1, map01,
                          "E1M1 and MAP01 reported the same automap bounds; did the automap open? \(bounds)")
        // ...and E1M1 after MAP01 got its own bounds back.
        XCTAssertEqual(e1m1Again, e1m1,
                       "E1M1's automap after Phase 2's MAP01 kept another map's bounds: \(bounds)")
    }

    /// A debug label's text, attached to the test report.
    private func label(_ app: XCUIApplication, _ identifier: String, name: String) -> String? {
        let element = app.staticTexts[identifier]
        guard element.waitForExistence(timeout: 5) else { return nil }
        let attachment = XCTAttachment(string: element.label)
        attachment.name = "\(name)-\(identifier)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return element.label
    }

    /// Plays a tile for one autoquit window and returns what the session that
    /// just ended started with.
    private func play(_ app: XCUIApplication, tile: XCUIElement, name: String,
                      file: StaticString = #filePath, line: UInt = #line,
                      during: (() -> Void)? = nil) -> String {
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "\(name): tile missing",
                      file: file, line: line)
        let exitLabel = app.staticTexts["engineExitLabel"]
        let start = Date()
        tile.tap()
        XCTAssertTrue(exitLabel.waitForNonExistence(timeout: 15),
                      "\(name): previous exit label never cleared", file: file, line: line)
        during?()
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90),
                      "\(name): engine never returned to the launcher", file: file, line: line)
        XCTAssertEqual(exitLabel.label, "Engine exited: 0",
                       "\(name): engine exit code was not 0", file: file, line: line)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, autoquitSeconds - 1.0,
            "\(name): session died before its autoquit window (\(elapsed)s)",
            file: file, line: line)

        let state = app.staticTexts["sessionStartStateLabel"]
        guard state.waitForExistence(timeout: 5) else { return "" }
        let attachment = XCTAttachment(string: state.label)
        attachment.name = "\(name)-session-start-state"
        attachment.lifetime = .keepAlways
        add(attachment)
        return state.label
    }

    /// Compares key by key, so a red run names the variable that leaked.
    private func assertSameFields(_ actual: String, _ expected: String, _ message: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let a = Self.fields(actual), e = Self.fields(expected)
        let differing = Set(a.keys).union(e.keys).sorted().filter { a[$0] != e[$0] }
        XCTAssertTrue(differing.isEmpty,
                      "\(message): " + differing.map { "\($0) \(e[$0] ?? "nil") -> \(a[$0] ?? "nil")" }
                          .joined(separator: ", "),
                      file: file, line: line)
    }

    /// "exit=0 wipe=3/-1 ..." -> ["exit": "0", "wipe": "3/-1", ...]
    static func fields(_ state: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in state.split(separator: " ") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
        return result
    }
}
