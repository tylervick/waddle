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
            assertSameFields(entry ?? "", Self.freshEntry(dehtab: Self.fields(entry1 ?? "")["dehtab"]),
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
        let firstLumps = zoneKB(app, name: "t1", field: "zlumps")
        let second = play(app, tile: phase2, name: "t2-phase2-after-title-quit")
        let secondZone = zoneKB(app, name: "t2")
        let secondLumps = zoneKB(app, name: "t2", field: "zlumps")

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

        // And the lump cache (#269): the previous session's cached lumps and
        // patches used to stay behind: 14 MB per title-only session with Freedoom
        // (14042 -> 28151 KB with W_Close's free removed).
        guard let la = firstLumps, let lb = secondLumps else {
            return XCTFail("no zlumps=<KB> from sessionStartZoneLabel (missing or unparseable; see the attachments)")
        }
        XCTAssertLessThan(lb - la, 256,
            "cached-lump zone memory grew by \(lb - la) KB between two title-only sessions (\(la) -> \(lb))")
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
    private func zoneKB(_ app: XCUIApplication, name: String, field: String = "zowned") -> Int? {
        let label = app.staticTexts["sessionStartZoneLabel"]
        guard label.waitForExistence(timeout: 5) else { return nil }
        let attachment = XCTAttachment(string: label.label)
        attachment.name = "\(name)-session-start-zone"
        attachment.lifetime = .keepAlways
        add(attachment)
        return Self.fields(label.label)[field].flatMap(Int.init)
    }

    /// What a fresh process hands its first session (WoofIOS_DebugSessionEntryState).
    /// dehtab is a hash of engine tables, so each test takes it from its own
    /// first session instead (freshEntry(dehtab:)).
    static let freshEntryBase = "amlvl=-1/-1 amstop=1 amdef=0 amcol=1 msg=0/0 sbar=0 rewind=0 "
        + "pad=0 rumble=0 tex=0 cmap=0 skipbl=0 dehstr=0 dehfiles=0 cheats=0 pars=0 dloop=0 "
        + "dirtylv=0 compres=0"

    static func freshEntry(dehtab: String?) -> String {
        freshEntryBase + " dehtab=\(dehtab ?? "missing")"
    }

    /// Issue #268: p_dirty's archive of completed levels and
    /// G_ApplyLevelCompatibility's saved options both outlived a session.
    /// Neither is reachable from a Freedoom session on its own (it takes a
    /// completed level, and a map COMPDB knows), so two test-only hooks force
    /// them: WADDLE_DEBUG_ARCHIVE_LEVEL archives the level on load, and
    /// WADDLE_DEBUG_COMPDB_MATCH makes COMPDB's first record match it.
    @MainActor
    func testArchivedLevelsAndCompatibilityRestoreDoNotLeak() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launchEnvironment["WADDLE_DEBUG_SESSION_START"] = "1"
        app.launchEnvironment["WADDLE_TEST_WARP"] = "1"
        app.launchEnvironment["WADDLE_DEBUG_ARCHIVE_LEVEL"] = "1"
        app.launchEnvironment["WADDLE_DEBUG_COMPDB_MATCH"] = "1"
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }

        let phase2 = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'game-' AND identifier CONTAINS 'Freedoom Phase 2'"))
            .firstMatch

        _ = play(app, tile: phase2, name: "h1-map01")
        let entry1 = try XCTUnwrap(label(app, "sessionEntryStateLabel", name: "h1"))
        let now1 = try XCTUnwrap(label(app, "levelStateNowLabel", name: "h1"))
        _ = play(app, tile: phase2, name: "h2-map01-again")
        let entry2 = try XCTUnwrap(label(app, "sessionEntryStateLabel", name: "h2"))

        let fresh = Self.freshEntry(dehtab: Self.fields(entry1)["dehtab"])
        assertSameFields(entry1, fresh, "session 1 was not handed fresh state")
        // The hooks really fired during session 1...
        XCTAssertNotEqual(Self.fields(now1)["dirtylv"], "0", "no level was archived: \(now1)")
        XCTAssertEqual(Self.fields(now1)["compres"], "1", "no COMPDB restore was pending: \(now1)")
        // ...and session 2 starts from neither.
        assertSameFields(entry2, fresh, "session 2 inherited session 1's level archive or COMPDB state")
    }

    /// A DEHACKED patch touching every table DEH_ResetSession restores.
    static let modPatch = """
        Patch File for DeHackEd v3.0
        Doom version = 21
        Patch format = 6

        Weapon 1
        Ammo per shot = 3

        Ammo 0
        Max ammo = 123

        Misc 0
        Initial Health = 150

        Cheat 0
        Chainsaw = zzchop

        [STRINGS]
        GOTARMOR = Waddle armor

        [PARS]
        par 1 1 999
        par 1 999
        """

    /// Issue #270: a modded session (DEHACKED loaded with -deh) must not leave
    /// its weapons, ammo, misc values, cheats, par times, strings or -deh file
    /// list to the next session, which loads no patch at all.
    @MainActor
    func testModdedSessionDoesNotLeakIntoTheNext() throws {
        autoquitSeconds = 8.0
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launchEnvironment["WADDLE_DEBUG_SESSION_START"] = "1"
        app.launchEnvironment["WADDLE_TEST_DEH_TEXT"] = Self.modPatch
        app.launchEnvironment["WADDLE_TEST_DEH_SESSIONS"] = "1"
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }

        let phase2 = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'game-' AND identifier CONTAINS 'Freedoom Phase 2'"))
            .firstMatch

        _ = play(app, tile: phase2, name: "d1-modded")
        let modEntry = try XCTUnwrap(label(app, "sessionEntryStateLabel", name: "d1"))
        let modNow = try XCTUnwrap(label(app, "dehNowLabel", name: "d1"))
        _ = play(app, tile: phase2, name: "d2-plain")
        let plainEntry = try XCTUnwrap(label(app, "sessionEntryStateLabel", name: "d2"))

        let fresh = Self.freshEntry(dehtab: Self.fields(modEntry)["dehtab"])
        assertSameFields(modEntry, fresh, "the modded session was not handed fresh state")
        // The patch really applied during session 1...
        let now = Self.fields(modNow)
        XCTAssertNotEqual(now["dehtab"], Self.fields(modEntry)["dehtab"],
                          "the weapon/ammo/misc patch never applied: \(modNow)")
        XCTAssertEqual(now["dehfiles"], "1", "the -deh file was not loaded: \(modNow)")
        XCTAssertNotEqual(now["cheats"], "0", "the Cheat patch never applied: \(modNow)")
        XCTAssertNotEqual(now["pars"], "0", "the [PARS] patch never applied: \(modNow)")
        // ...and session 2, which loads no patch, starts from none of it.
        assertSameFields(plainEntry, fresh, "the plain session inherited the modded one's patch")
    }

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
            assertSameFields(entry ?? "", Self.freshEntry(dehtab: Self.fields(entries[0] ?? "")["dehtab"]),
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
        // What a reader of the screen sees (the Revyl test reads pixels, not
        // identifiers), kept with the run.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(name)-shelf-after-session"
        shot.lifetime = .keepAlways
        add(shot)
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
