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
        let phase2First = play(app, tile: phase2, name: "s2-phase2-first")
        let phase2Second = play(app, tile: phase2, name: "s3-phase2-second")
        let phase1Again = play(app, tile: phase1, name: "s4-phase1-again")

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

    /// Plays a tile for one autoquit window and returns what the session that
    /// just ended started with.
    private func play(_ app: XCUIApplication, tile: XCUIElement, name: String,
                      file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "\(name): tile missing",
                      file: file, line: line)
        let exitLabel = app.staticTexts["engineExitLabel"]
        let start = Date()
        tile.tap()
        XCTAssertTrue(exitLabel.waitForNonExistence(timeout: 15),
                      "\(name): previous exit label never cleared", file: file, line: line)
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
