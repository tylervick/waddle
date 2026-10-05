import XCTest

/// Issue #79: the Woof re-vendor (#328) was done for two untrusted-WAD fixes,
/// `cc1d13e9` (the ZNOD inflate loop reset its output pointer as if every
/// resize had been filled, so compressed nodes past the first buffer landed
/// at the wrong offset) and `42470994` (format detection ran before anyone
/// checked that a BLOCKMAP lump existed). Nothing in CI loaded a map that
/// reaches either path: the bundled Freedoom maps carry vanilla nodes and
/// blockmaps, and the real PWADs that do not are copyrighted and local-only
/// (`RealWADTests`).
///
/// `Fixtures/freedoom-e1m1-znod.wad` is Freedoom's E1M1 with its nodes rebuilt
/// by ZDBSP in the compressed extended format (see the README beside it).
/// Session 1 loads it over Phase 1 and warps into E1M1; session 2 loads the
/// same file with its BLOCKMAP lump emptied, so the engine has to build one.
/// `levelStateNowLabel` (`WoofIOS_DebugLevelStateNow`) reports the node and
/// blockmap format of the last level set up, which is what proves each
/// session took the path under test rather than merely not crashing: the
/// IWAD's own E1M1 would report `DoomBSP`.
final class CompressedNodesTests: XCTestCase {

    private let autoquitSeconds = 8.0

    @MainActor
    func testCompressedNodesMapLoadsWithAndWithoutABlockmap() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "freedoom-e1m1-znod",
                                                           withExtension: "wad"),
                                "fixture missing from the UI test bundle (run `mise run generate`)")
        let wad = try Data(contentsOf: url)
        XCTAssertEqual(Self.lumpSignature(named: "NODES", in: wad), "ZNOD",
                       "the fixture's nodes are not compressed; regenerate it per Fixtures/README.md")
        let noBlockmap = try Self.emptyingLump(named: "BLOCKMAP", in: wad)

        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launchEnvironment["WADDLE_DEBUG_SESSION_START"] = "1"
        app.launchEnvironment["WADDLE_TEST_WARP"] = "1"
        app.launchEnvironment["WADDLE_TEST_NOGUI"] = "1"
        app.launchEnvironment["WADDLE_TEST_ZIP_1"] =
            SessionStartStateTests.storedZip(name: "freedoom-e1m1-znod.wad", data: wad).base64EncodedString()
        app.launchEnvironment["WADDLE_TEST_ZIP_2"] =
            SessionStartStateTests.storedZip(name: "freedoom-e1m1-znod.wad", data: noBlockmap).base64EncodedString()
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }
        let phase1 = app.buttons["playFreedoom1"]

        play(app, tile: phase1, name: "n1-compressed-nodes")
        let now1 = try XCTUnwrap(label(app, "levelStateNowLabel", name: "n1"))
        let f1 = SessionStartStateTests.fields(now1)
        XCTAssertEqual(f1["nodes"], "ZNOD", "session 1 did not load the PWAD's compressed nodes: \(now1)")
        XCTAssertEqual(f1["bmap"], "lump", "session 1 should have used the PWAD's BLOCKMAP lump: \(now1)")

        play(app, tile: phase1, name: "n2-compressed-nodes-no-blockmap")
        let now2 = try XCTUnwrap(label(app, "levelStateNowLabel", name: "n2"))
        let f2 = SessionStartStateTests.fields(now2)
        XCTAssertEqual(f2["nodes"], "ZNOD", "session 2 did not load the PWAD's compressed nodes: \(now2)")
        XCTAssertEqual(f2["bmap"], "BoomBlockmap",
                       "session 2 had an empty BLOCKMAP lump and should have built one: \(now2)")
    }

    // MARK: - WAD directory helpers

    /// The first four bytes of the named lump, as ASCII, or nil.
    static func lumpSignature(named name: String, in wad: Data) -> String? {
        guard let entry = directory(of: wad).first(where: { $0.name == name }), entry.size >= 4 else {
            return nil
        }
        return String(decoding: wad[entry.filepos..<entry.filepos + 4], as: UTF8.self)
    }

    /// A copy of `wad` whose directory entry for `name` has size 0, which is
    /// how a map without that lump reads to the engine (the bytes stay, the
    /// directory no longer points at them).
    static func emptyingLump(named name: String, in wad: Data) throws -> Data {
        guard let entry = directory(of: wad).first(where: { $0.name == name }) else {
            throw XCTSkip("fixture has no \(name) lump")
        }
        var copy = wad
        copy.replaceSubrange(entry.sizeOffset..<entry.sizeOffset + 4, with: [0, 0, 0, 0])
        return copy
    }

    private struct Entry { let name: String; let filepos: Int; let size: Int; let sizeOffset: Int }

    private static func directory(of wad: Data) -> [Entry] {
        guard wad.count >= 12 else { return [] }
        let count = Int(le32(wad, 4)), offset = Int(le32(wad, 8))
        guard count >= 0, offset >= 0, offset + count * 16 <= wad.count else { return [] }
        return (0..<count).map { i in
            let base = offset + i * 16
            let nameBytes = wad[base + 8..<base + 16].prefix { $0 != 0 }
            return Entry(name: String(decoding: nameBytes, as: UTF8.self),
                         filepos: Int(le32(wad, base)), size: Int(le32(wad, base + 4)),
                         sizeOffset: base + 4)
        }
    }

    private static func le32(_ data: Data, _ at: Int) -> UInt32 {
        data[at..<at + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    // MARK: - Session helpers (as SessionStartStateTests', which are private)

    private func label(_ app: XCUIApplication, _ identifier: String, name: String) -> String? {
        let element = app.staticTexts[identifier]
        guard element.waitForExistence(timeout: 5) else { return nil }
        let attachment = XCTAttachment(string: element.label)
        attachment.name = "\(name)-\(identifier)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return element.label
    }

    /// Plays a tile for one autoquit window and requires a clean exit that
    /// lasted the whole window.
    private func play(_ app: XCUIApplication, tile: XCUIElement, name: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "\(name): tile missing", file: file, line: line)
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
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(name)-shelf-after-session"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
