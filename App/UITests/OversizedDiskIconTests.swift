import XCTest

/// Issue #527: `I_InitDiskFlash` (`Engine/woof/src/i_video.c`) allocates a
/// buffer for a 16x16 disk icon and drew the WAD's `STDISK` patch into it
/// uncropped, so a PWAD whose `STDISK` is larger wrote past that heap buffer
/// at every video init. Any imported file reaches the engine with `-file`, so
/// that is untrusted input. Upstream fixed it as a crash in `ae2e5b3e`
/// (fabiangreffrath/woof#3023), which Waddle carries as a backport until the
/// Woof pin contains it (`Engine/WOOF_UPSTREAM.md`).
///
/// The fixture is built here rather than committed: a PWAD holding only an
/// opaque `STDISK` patch of `iconWidth` x `iconHeight`, loaded over Freedoom
/// Phase 1 through the `WADDLE_TEST_ZIP_<n>` seam. The first launch plays one
/// session to the title screen; the second warps into E1M1 twice. Each session
/// must last its whole autoquit window and exit 0.
///
/// Without the fix, where the overflow shows depends on heap layout, so the
/// failure point moves between runs: the title-screen session has always
/// survived it, the first warped session sometimes crashes or ends in
/// `I_Error` ("freed a pointer without ZONEID") and sometimes exits 0, and
/// then the second warped session, which frees and reallocates the trampled
/// buffer and walks the zone again in level setup, is what fails. That is why
/// there are two warped sessions. Failing without the fix is likely, not
/// guaranteed (docs/learnings/an-engine-heap-overflow-surfaces-at-a-later-free.md).
final class OversizedDiskIconTests: XCTestCase {

    private let autoquitSeconds = 8.0

    /// Far past 16x16 in both directions; a column-major screen buffer means
    /// both the extra columns and the extra rows land outside `diskflash`.
    static let iconWidth = 64
    static let iconHeight = 64

    @MainActor
    func testOversizedSTDISKReachesTheTitleScreenAndALevel() throws {
        let pwad = Self.diskIconPWAD(width: Self.iconWidth, height: Self.iconHeight)
        let zip = SessionStartStateTests.storedZip(name: "big-stdisk.wad", data: pwad).base64EncodedString()

        // Launch 1: the title screen (no warp).
        var app = launch(environment: ["WADDLE_TEST_ZIP_1": zip])
        play(app, name: "d1-title-screen")
        app.terminate()

        // Launch 2: two sessions in E1M1.
        app = launch(environment: ["WADDLE_TEST_WARP": "1",
                                   "WADDLE_TEST_ZIP_1": zip,
                                   "WADDLE_TEST_ZIP_2": zip])
        play(app, name: "d2-level")
        let now = try XCTUnwrap(label(app, "levelStateNowLabel", name: "d2"))
        XCTAssertNotEqual(SessionStartStateTests.fields(now)["nodes"], "none",
                          "the warped session never set up a level: \(now)")
        play(app, name: "d3-level-second-session")
    }

    // MARK: - Fixture

    /// A PWAD with one lump, `STDISK`: a Doom picture of `width` x `height`,
    /// every column a single opaque post of palette index 176 (red), offsets 0.
    static func diskIconPWAD(width: Int, height: Int) -> Data {
        precondition(width > 0 && height > 0 && height <= 254, "one post per column holds at most 254 rows")
        var patch = Data()
        patch.appendLE16(UInt16(width)); patch.appendLE16(UInt16(height))
        patch.appendLE16(0); patch.appendLE16(0)                     // leftoffset, topoffset
        let columnSize = 3 + height + 2                              // topdelta, length, pad, pixels, pad, 0xFF
        let firstColumn = 8 + 4 * width
        for x in 0..<width { patch.appendLE32(UInt32(firstColumn + x * columnSize)) }
        for _ in 0..<width {
            patch.append(contentsOf: [0, UInt8(height), 0])
            patch.append(Data(repeating: 176, count: height))
            patch.append(contentsOf: [0, 0xFF])
        }

        var wad = Data("PWAD".utf8)
        wad.appendLE32(1)                                            // lump count
        wad.appendLE32(UInt32(12 + patch.count))                     // directory offset
        wad += patch
        wad.appendLE32(12); wad.appendLE32(UInt32(patch.count))
        wad += Data("STDISK\0\0".utf8)
        return wad
    }

    // MARK: - Session helpers (as CompressedNodesTests')

    private func launch(environment: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.provideFreedoom()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launchEnvironment["WADDLE_DEBUG_SESSION_START"] = "1"
        app.launchEnvironment["WADDLE_TEST_NOGUI"] = "1"
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90),
                      "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }
        return app
    }

    private func label(_ app: XCUIApplication, _ identifier: String, name: String) -> String? {
        let element = app.staticTexts[identifier]
        guard element.waitForExistence(timeout: 5) else { return nil }
        let attachment = XCTAttachment(string: element.label)
        attachment.name = "\(name)-\(identifier)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return element.label
    }

    /// Plays Freedoom Phase 1 for one autoquit window and requires a clean
    /// exit that lasted the whole window: an engine that crashed on the
    /// overflow takes the app with it, and the exit label never appears.
    private func play(_ app: XCUIApplication, name: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        let tile = app.buttons["playFreedoom1"]
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

private extension Data {
    mutating func appendLE16(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}
