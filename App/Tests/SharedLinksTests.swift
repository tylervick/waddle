import SwiftData
import XCTest
@testable import Waddle

/// A link shared to Waddle from another app's share sheet (#551): the share
/// extension leaves it in `PendingLinkInbox`, and Waddle takes it when it
/// next opens and queues it on `LinkImport` as a dropped link
/// (`SharedLinks.pickUp`). A temporary directory stands in for the App
/// Group's container.
@MainActor
final class SharedLinksTests: XCTestCase {
    private var tmp: URL!
    private var inboxDir: URL!

    /// A clock the test moves by hand.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    override func setUpWithError() throws {
        StubURLProtocol.reset()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        inboxDir = tmp.appendingPathComponent(PendingLinkInbox.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: tmp)
    }

    private func inbox(_ clock: Clock = Clock()) -> PendingLinkInbox {
        PendingLinkInbox(directory: inboxDir, now: { clock.now })
    }

    private func filesInInbox() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: inboxDir.path)) ?? []
    }

    /// Writes a link file by hand, as some other writer than `add` might.
    private func writeEntry(_ link: String, sharedAt date: Date, named name: String) throws {
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(PendingLinkInbox.Entry(url: URL(string: link)!, sharedAt: date))
        try data.write(to: inboxDir.appendingPathComponent(name))
    }

    // MARK: The inbox

    func testALinkIsReadBackOnceAndThenGone() throws {
        let inbox = inbox()
        let link = "https://files.example/maps/scythe.zip"

        XCTAssertEqual(try inbox.add(link).get(), URL(string: link))
        XCTAssertEqual(filesInInbox().count, 1)

        XCTAssertEqual(inbox.take(), [URL(string: link)!])
        XCTAssertEqual(filesInInbox(), [], "a taken link's file is removed")
        XCTAssertEqual(inbox.take(), [], "and it is not taken a second time")
    }

    func testSeveralLinksAreReadOldestFirst() throws {
        let clock = Clock()
        let inbox = inbox(clock)
        let links = ["https://files.example/c.wad", "https://files.example/a.wad",
                     "https://files.example/b.wad", "https://files.example/d.wad"]
        for link in links {
            _ = try inbox.add(link).get()
            clock.advance(60)
        }

        XCTAssertEqual(inbox.take().map(\.absoluteString), links)
    }

    /// Ordered by the time in the file, not its name: a file whose name
    /// sorts first but was shared last still comes out last.
    func testOrderIsByTheTimeWrittenInTheFile() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try writeEntry("https://files.example/second.wad", sharedAt: base + 60, named: "a.json")
        try writeEntry("https://files.example/first.wad", sharedAt: base, named: "b.json")

        XCTAssertEqual(inbox().take().map(\.lastPathComponent), ["first.wad", "second.wad"])
    }

    func testAnHTTPLinkIsRefusedAtWriteTimeWithTheAppsReason() {
        let result = inbox().add("http://files.example/map.wad")

        XCTAssertEqual(result, .failure(.link(.insecure)))
        if case .failure(let refusal) = result {
            XCTAssertEqual(refusal.reason, LinkDownloadError.insecure.reason)
        }
        XCTAssertEqual(filesInInbox(), [], "nothing is written for a refused link")
    }

    func testTextThatIsNotALinkIsRefusedWithTheAppsReason() {
        XCTAssertEqual(inbox().add("Note: hi"), .failure(.link(.notALink)))
        XCTAssertEqual(filesInInbox(), [])
    }

    func testAFileThatDoesNotDecodeIsDeletedAndSkipped() throws {
        let inbox = inbox()
        _ = try inbox.add("https://files.example/good.wad").get()
        try Data("{ not json".utf8).write(to: inboxDir.appendingPathComponent("0-broken.json"))
        try Data(#"{"url": 7}"#.utf8).write(to: inboxDir.appendingPathComponent("1-wrong.json"))

        XCTAssertEqual(inbox.take().map(\.lastPathComponent), ["good.wad"])
        XCTAssertEqual(filesInInbox(), [], "the files that did not decode are removed too")
    }

    func testALinkOlderThanSevenDaysIsDropped() throws {
        let clock = Clock()
        let inbox = inbox(clock)
        _ = try inbox.add("https://files.example/old.wad").get()
        clock.advance(PendingLinkInbox.maxAge - 60)
        _ = try inbox.add("https://files.example/recent.wad").get()
        clock.advance(120)

        XCTAssertEqual(inbox.take().map(\.lastPathComponent), ["recent.wad"])
        XCTAssertEqual(filesInInbox(), [], "the expired link's file is removed")
    }

    func testTheInboxRefusesALinkOnceItIsFull() throws {
        let inbox = inbox()
        for index in 0..<PendingLinkInbox.capacity {
            _ = try inbox.add("https://files.example/\(index).wad").get()
        }

        XCTAssertEqual(inbox.add("https://files.example/one-more.wad"), .failure(.full))
        XCTAssertEqual(filesInInbox().count, PendingLinkInbox.capacity)
        _ = inbox.take()
        XCTAssertNoThrow(try inbox.add("https://files.example/one-more.wad").get(),
                         "taking the links makes room again")
    }

    func testTakeWithALimitLeavesTheRestForNextTime() throws {
        let clock = Clock()
        let inbox = inbox(clock)
        for name in ["a", "b", "c"] {
            _ = try inbox.add("https://files.example/\(name).wad").get()
            clock.advance(1)
        }

        XCTAssertEqual(inbox.take(limit: 2).map(\.lastPathComponent), ["a.wad", "b.wad"])
        XCTAssertEqual(inbox.take().map(\.lastPathComponent), ["c.wad"])
    }

    /// No group container: CI's unsigned simulator builds, whose bundle
    /// still names the group but carries no entitlement for it.
    func testThereIsNoSharedInboxWithoutAnAppGroup() {
        XCTAssertNil(PendingLinkInbox.shared(bundle: Bundle(for: SharedLinksTests.self)),
                     "the test bundle names no App Group")
    }

    // MARK: The pick-up

    func testThePickUpHandsEveryLinkToTheDroppedLinkQueueInOneCall() throws {
        let clock = Clock()
        let inbox = inbox(clock)
        for name in ["a", "b"] {
            _ = try inbox.add("https://files.example/\(name).wad").get()
            clock.advance(1)
        }
        var calls: [(urls: [URL], extras: LinkImport.Extras)] = []

        let started = SharedLinks.pickUp(from: inbox) { calls.append(($0, $1)) }

        XCTAssertTrue(started)
        XCTAssertEqual(calls.count, 1, "one batch, so one notice")
        XCTAssertEqual(calls.first?.urls.map(\.lastPathComponent), ["a.wad", "b.wad"])
        XCTAssertTrue(calls.first?.extras.isEmpty ?? false)
        XCTAssertEqual(filesInInbox(), [])
    }

    func testThePickUpHandsNothingOverWhenThereIsNothingWaiting() {
        var calls = 0
        XCTAssertFalse(SharedLinks.pickUp(from: inbox()) { _, _ in calls += 1 })
        XCTAssertFalse(SharedLinks.pickUp(from: nil) { _, _ in calls += 1 })
        XCTAssertEqual(calls, 0)
    }

    /// A file the extension did not write through `add` is checked again,
    /// as a dropped link is, and refused with its reason in the notice.
    func testThePickUpRefusesAnHTTPLinkItFindsWithItsReason() throws {
        try writeEntry("http://files.example/x.wad", sharedAt: Date(timeIntervalSince1970: 1_800_000_000),
                       named: "0.json")
        var calls: [(urls: [URL], extras: LinkImport.Extras)] = []

        XCTAssertFalse(SharedLinks.pickUp(from: inbox()) { calls.append(($0, $1)) })

        XCTAssertEqual(calls.first?.urls, [])
        XCTAssertEqual(calls.first?.extras.refused.map { $0.error }, [.insecure])
    }

    func testThePickUpTakesNoMoreThanADropAndLeavesTheRest() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let count = WADDrop.maxLinksPerDrop + 2
        for index in 0..<count {
            try writeEntry("https://files.example/\(index).wad", sharedAt: base + Double(index),
                           named: "\(index).json")
        }
        var taken: [URL] = []

        SharedLinks.pickUp(from: inbox()) { urls, _ in taken += urls }
        XCTAssertEqual(taken.count, WADDrop.maxLinksPerDrop)
        XCTAssertEqual(taken.first?.lastPathComponent, "0.wad")

        SharedLinks.pickUp(from: inbox()) { urls, _ in taken += urls }
        XCTAssertEqual(taken.map(\.lastPathComponent), (0..<count).map { "\($0).wad" })
    }

    // MARK: Through the real queue

    /// A link shared twice before Waddle opens is downloaded twice, and the
    /// second is reported as already in the library, in the queue's one
    /// notice, by the dedupe every import goes through.
    func testALinkSharedTwiceIsDownloadedTwiceAndReportedAlreadyInLibrary() async throws {
        let link = "https://files.example/download?id=7"
        StubURLProtocol.set(.respond(status: 200, headers: [
            "Content-Type": "application/octet-stream",
            "Content-Disposition": #"attachment; filename="map.wad""#,
        ], body: makeWAD(magic: "PWAD", lumps: ["MAP01"])), for: link)
        let clock = Clock()
        let inbox = inbox(clock)
        _ = try inbox.add(link).get()
        clock.advance(5)
        _ = try inbox.add(link).get()

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Game.self, configurations: config)
        let store = WADStore(directory: tmp.appendingPathComponent("WADs", isDirectory: true))
        let library = LibraryService(context: ModelContext(container), store: store)
        let notices = ImportNotices()
        let importer = ImportService(library: library, store: store, notices: notices,
                                     usage: UsageStore(directory: tmp.appendingPathComponent("Diagnostics",
                                                                                             isDirectory: true)))
        var downloader = LinkDownloader()
        downloader.directory = tmp.appendingPathComponent("LinkDownloads", isDirectory: true)
        downloader.makeConfiguration = { StubURLProtocol.configuration() }
        let links = LinkImport(importer: importer, downloader: downloader, notices: notices)

        XCTAssertTrue(SharedLinks.pickUp(from: inbox) { links.enqueue($0, extras: $1) })
        let deadline = Date().addingTimeInterval(20)
        while links.isBusy, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(links.isBusy)
        XCTAssertEqual(StubURLProtocol.requestedURLs, [link, link])
        XCTAssertEqual(try library.allWADs().map(\.filename), ["map.wad"])
        let notice = try XCTUnwrap(notices.current)
        XCTAssertTrue(notice.contains("1 already in library"), notice)
    }
}
