import XCTest

/// A link shared to Waddle from another app's share sheet (#551) while
/// Waddle had a sheet open. Waddle must not download it unseen: it waits
/// until the shelf can show the From a Link sheet, and the player then sees
/// how it ended. Review of pull request 561 found it downloading under the
/// open Settings sheet, with its notice expiring there.
///
/// The share extension cannot run under a UI test, and the runner builds
/// unsigned, with no App Group, so the test stands in for the extension:
/// it writes the link's file into a folder the app is told to use as its
/// inbox (`WADDLE_TEST_PENDING_LINKS_DIR`), as `PendingLinkInbox.add` does.
final class SharedLinkUITests: XCTestCase {
    private var inbox: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        inbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SharedLinkUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: inbox)
    }

    /// The files waiting in the stand-in inbox.
    private var waiting: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []).filter { $0.hasSuffix(".json") }
    }

    /// Writes one link as the share extension would: `PendingLinkInbox.Entry`
    /// encoded by `JSONEncoder`, whose dates are seconds since 2001.
    private func share(_ link: String) throws {
        let json = #"{"url":"\#(link)","sharedAt":\#(Date().timeIntervalSinceReferenceDate)}"#
        try Data(json.utf8).write(to: inbox.appendingPathComponent("link-0.json"))
    }

    @MainActor
    func testALinkSharedWhileSettingsIsOpenWaitsAndIsThenShown() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launchEnvironment["WADDLE_TEST_PENDING_LINKS_DIR"] = inbox.path
        app.launch()
        XCTAssertTrue(app.buttons["importButton"].waitForExistence(timeout: 10), "the shelf never appeared")

        // Settings is a sheet on a phone. Leave it open, go Home, share.
        app.buttons["touchSchemeMenu"].tap()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Settings did not open")
        XCUIDevice.shared.press(.home)
        // A port nothing listens on: the download fails at once, with a
        // reason the notice has to show.
        try share("https://127.0.0.1:9/shared.wad")
        app.activate()
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Settings is no longer up")

        // Held while Settings covers the shelf: not taken, not downloading.
        let linkSheet = app.navigationBars["Add From a Link"]
        let banner = app.descendants(matching: .any).matching(identifier: "importNoticeBanner").firstMatch
        let heldUntil = Date().addingTimeInterval(4)
        while Date() < heldUntil {
            XCTAssertEqual(waiting.count, 1, "the link was taken while Settings covered the shelf")
            XCTAssertFalse(banner.exists, "a notice was posted under the open sheet")
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Back on the shelf: the download runs where the player sees it, and
        // its notice says how it ended.
        done.tap()
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "no notice after Settings closed")
        XCTAssertTrue(banner.label.contains("could not reach the server") || banner.label.contains("Import failed"),
                      "the notice does not say why: \(banner.label)")
        let closed = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: closed, evaluatedWith: linkSheet)], timeout: 5),
                       .completed, "the From a Link sheet stayed open after the download ended")
        let gone = Date().addingTimeInterval(5)
        while !waiting.isEmpty, Date() < gone { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(waiting, [], "the link stayed in the inbox after its result was shown")
    }
}
