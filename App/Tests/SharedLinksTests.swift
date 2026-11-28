import SwiftData
import UIKit
import XCTest
@testable import Waddle

/// A link shared to Waddle from another app's share sheet (#551): the share
/// extension leaves it in `PendingLinkInbox`, and Waddle picks it up when it
/// next opens and queues it on `LinkImport` as a dropped link
/// (`SharedLinkPickup`). A temporary directory stands in for the App Group's
/// container.
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

    /// What a pick-up handed to the queue, and the queue's completion, which
    /// the test calls when it wants the queue to have ended.
    private struct Call {
        var urls: [URL]
        var extras: LinkImport.Extras
        var finish: @MainActor () -> Void
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
        EngineSession.setRunningForTesting(false)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func inbox(_ clock: Clock = Clock()) -> PendingLinkInbox {
        PendingLinkInbox(directory: inboxDir, now: { clock.now })
    }

    private func filesInInbox() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: inboxDir.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    /// Writes a link file by hand, as some other writer than `add` might.
    private func writeEntry(_ link: String, sharedAt date: Date, named name: String) throws {
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(PendingLinkInbox.Entry(url: URL(string: link)!, sharedAt: date))
        try data.write(to: inboxDir.appendingPathComponent(name))
    }

    /// A pick-up over this test's inbox that may present when `canPresent`
    /// says so.
    private func pickup(_ inbox: PendingLinkInbox? = nil, canPresent: @escaping () -> Bool = { true })
        -> SharedLinkPickup {
        let inbox = inbox ?? self.inbox()
        return SharedLinkPickup(inbox: { inbox }, canPresent: canPresent, retryInterval: .milliseconds(10))
    }

    // MARK: The inbox

    func testALinkStaysUntilItIsRemovedAndThenIsGone() throws {
        let inbox = inbox()
        let link = "https://files.example/maps/scythe.zip"

        XCTAssertEqual(try inbox.add(link).get(), URL(string: link))
        let waiting = inbox.waiting()
        XCTAssertEqual(waiting.map(\.url), [URL(string: link)!])
        XCTAssertEqual(inbox.waiting(), waiting, "reading a link does not remove it")

        inbox.remove(waiting)
        XCTAssertEqual(inbox.waiting(), [])
        XCTAssertEqual(filesInInbox(), [], "a removed link's file is gone")
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

        XCTAssertEqual(inbox.waiting().map(\.url.absoluteString), links)
    }

    /// Ordered by the time in the file, not its name: a file whose name
    /// sorts first but was shared last still comes out last.
    func testOrderIsByTheTimeWrittenInTheFile() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try writeEntry("https://files.example/second.wad", sharedAt: base + 60, named: "a.json")
        try writeEntry("https://files.example/first.wad", sharedAt: base, named: "b.json")

        XCTAssertEqual(inbox().waiting().map(\.url.lastPathComponent), ["first.wad", "second.wad"])
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

        XCTAssertEqual(inbox.waiting().map(\.url.lastPathComponent), ["good.wad"])
        XCTAssertEqual(filesInInbox(), [PendingLinkInbox.slotName(0)],
                       "the files that did not decode are removed")
    }

    func testALinkOlderThanSevenDaysIsDropped() throws {
        let clock = Clock()
        let inbox = inbox(clock)
        _ = try inbox.add("https://files.example/old.wad").get()
        clock.advance(PendingLinkInbox.maxAge - 60)
        _ = try inbox.add("https://files.example/recent.wad").get()
        clock.advance(120)

        XCTAssertEqual(inbox.waiting().map(\.url.lastPathComponent), ["recent.wad"])
        XCTAssertEqual(filesInInbox().count, 1, "the expired link's file is removed")
    }

    func testTheInboxRefusesALinkOnceItIsFull() throws {
        let inbox = inbox()
        for index in 0..<PendingLinkInbox.capacity {
            _ = try inbox.add("https://files.example/\(index).wad").get()
        }

        XCTAssertEqual(inbox.add("https://files.example/one-more.wad"), .failure(.full))
        XCTAssertEqual(filesInInbox().count, PendingLinkInbox.capacity)
        inbox.remove(Array(inbox.waiting().prefix(1)))
        XCTAssertNoThrow(try inbox.add("https://files.example/one-more.wad").get(),
                         "removing a link makes room again")
    }

    /// Two extensions at once (two Safari windows on an iPad) must not get
    /// past the cap together. Counting the files and then writing let 40
    /// writers at once leave 19 (review of pull request 561).
    func testTheCapHoldsWithManyWritersAtOnce() {
        let inbox = inbox()
        let writers = 40
        let results = Self.addConcurrently(writers, to: inbox)

        let added = results.values.filter { if case .success = $0 { true } else { false } }
        XCTAssertEqual(added.count, PendingLinkInbox.capacity, "exactly as many writers succeed as there are slots")
        XCTAssertEqual(results.values.filter { $0 == .failure(.full) }.count, writers - PendingLinkInbox.capacity,
                       "every other writer is told the inbox is full")
        XCTAssertEqual(filesInInbox().count, PendingLinkInbox.capacity)
        XCTAssertEqual(Set(inbox.waiting().map(\.url)).count, PendingLinkInbox.capacity,
                       "no writer overwrote another's link")
    }

    /// Off the main actor, so the writers really run at once.
    private nonisolated static func addConcurrently(_ writers: Int, to inbox: PendingLinkInbox)
        -> LockedArray<Result<URL, PendingLinkInbox.Refusal>> {
        let results = LockedArray<Result<URL, PendingLinkInbox.Refusal>>()
        DispatchQueue.concurrentPerform(iterations: writers) { index in
            results.append(inbox.add("https://files.example/\(index).wad"))
        }
        return results
    }

    func testWaitingWithALimitReturnsTheOldest() throws {
        let clock = Clock()
        let inbox = inbox(clock)
        for name in ["a", "b", "c"] {
            _ = try inbox.add("https://files.example/\(name).wad").get()
            clock.advance(1)
        }

        XCTAssertEqual(inbox.waiting(limit: 2).map(\.url.lastPathComponent), ["a.wad", "b.wad"])
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
        var calls: [Call] = []
        var started = 0

        let result = pickup(inbox).pickUp(into: { calls.append(Call(urls: $0, extras: $1, finish: $2)) },
                                          onStarted: { started += 1 })

        XCTAssertEqual(result, true)
        XCTAssertEqual(started, 1, "the shelf is asked to show the download")
        XCTAssertEqual(calls.count, 1, "one batch, so one notice")
        XCTAssertEqual(calls.first?.urls.map(\.lastPathComponent), ["a.wad", "b.wad"])
        XCTAssertTrue(calls.first?.extras.isEmpty ?? false)
    }

    func testThePickUpHandsNothingOverWhenThereIsNothingWaiting() {
        var calls = 0
        XCTAssertEqual(pickup().pickUp(into: { _, _, _ in calls += 1 }), false)
        let none = SharedLinkPickup(inbox: { nil }, canPresent: { true })
        XCTAssertEqual(none.pickUp(into: { _, _, _ in calls += 1 }), false)
        XCTAssertEqual(calls, 0)
    }

    /// A file the extension did not write through `add` is checked again,
    /// as a dropped link is, and refused with its reason in the notice.
    func testThePickUpRefusesAnHTTPLinkItFindsWithItsReason() throws {
        try writeEntry("http://files.example/x.wad", sharedAt: Date(timeIntervalSince1970: 1_800_000_000),
                       named: "0.json")
        var calls: [Call] = []

        XCTAssertEqual(pickup().pickUp(into: { calls.append(Call(urls: $0, extras: $1, finish: $2)) }), false)

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
        let pickup = pickup()
        var calls: [Call] = []

        pickup.pickUp(into: { calls.append(Call(urls: $0, extras: $1, finish: $2)) })
        XCTAssertEqual(calls.last?.urls.count, WADDrop.maxLinksPerDrop)
        XCTAssertEqual(calls.last?.urls.first?.lastPathComponent, "0.wad")

        pickup.pickUp(into: { calls.append(Call(urls: $0, extras: $1, finish: $2)) })
        XCTAssertEqual(calls.flatMap(\.urls).map(\.lastPathComponent), (0..<count).map { "\($0).wad" },
                       "the rest come next, and none twice")
    }

    // MARK: A link is kept until its result was shown

    /// The link stays in the inbox while it downloads, is not queued a
    /// second time in the same run, and is removed once the queue has ended
    /// (review of pull request 561: it was deleted before the download).
    func testALinkStaysInTheInboxUntilItsQueueHasEnded() throws {
        let inbox = inbox()
        _ = try inbox.add("https://files.example/map.wad").get()
        let pickup = pickup(inbox)
        var calls: [Call] = []

        pickup.pickUp(into: { calls.append(Call(urls: $0, extras: $1, finish: $2)) })
        XCTAssertEqual(filesInInbox().count, 1, "kept while it downloads")
        XCTAssertEqual(pickup.pickUp(into: { calls.append(Call(urls: $0, extras: $1, finish: $2)) }), false,
                       "a link already queued is not queued again")
        XCTAssertEqual(calls.count, 1)

        calls[0].finish()
        XCTAssertEqual(filesInInbox(), [], "removed once its result has been told")
        XCTAssertTrue(pickup.inFlight.isEmpty)
    }

    /// A link the app stopped while adding -- killed, or crashed, perhaps by
    /// the file itself -- is not tried again: the next launch's pick-up drops
    /// it once and the notice names it (re-review of pull request 561).
    /// Before, it was downloaded again on every launch for up to 7 days.
    func testALinkTheAppStoppedWhileAddingIsDroppedOnceWithANotice() throws {
        let inbox = inbox()
        _ = try inbox.add("https://files.example/crashes.zip").get()
        var calls: [Call] = []

        pickup(inbox).pickUp(into: { calls.append(Call(urls: $0, extras: $1, finish: $2)) })
        XCTAssertEqual(calls.last?.urls.map(\.lastPathComponent), ["crashes.zip"])
        XCTAssertEqual(inbox.waiting().map(\.attempted), [true], "marked before its download starts")
        // The app stops here: the queue never ends.

        let nextLaunch = pickup(inbox)
        let result = nextLaunch.pickUp(into: { calls.append(Call(urls: $0, extras: $1, finish: $2)) })
        XCTAssertEqual(result, false, "nothing is downloaded again")
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.urls, [])
        XCTAssertEqual(calls.last?.extras.refused.map { $0.url.lastPathComponent }, ["crashes.zip"])
        XCTAssertEqual(calls.last?.extras.refused.map { $0.error }, [.interrupted])
        XCTAssertEqual(filesInInbox(), [], "dropped at once, so it is told only once")

        nextLaunch.pickUp(into: { calls.append(Call(urls: $0, extras: $1, finish: $2)) })
        pickup(inbox).pickUp(into: { calls.append(Call(urls: $0, extras: $1, finish: $2)) })
        XCTAssertEqual(calls.count, 2, "and never again")
    }

    /// The drop is told through the queue's own notice, naming the link.
    func testTheInterruptedLinksNoticeNamesIt() throws {
        let inbox = inbox()
        _ = try inbox.add("https://files.example/crashes.zip").get()
        inbox.markAttempted(inbox.waiting())
        let notices = ImportNotices()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Game.self, configurations: config)
        let store = WADStore(directory: tmp.appendingPathComponent("WADs", isDirectory: true))
        let library = LibraryService(context: ModelContext(container), store: store)
        let importer = ImportService(library: library, store: store, notices: notices,
                                     usage: UsageStore(directory: tmp.appendingPathComponent("Diagnostics",
                                                                                             isDirectory: true)))
        let links = LinkImport(importer: importer, notices: notices)

        pickup(inbox).pickUp(into: { links.enqueue($0, extras: $1, onFinish: $2) })

        let notice = try XCTUnwrap(notices.current)
        XCTAssertTrue(notice.contains("crashes.zip"), notice)
        XCTAssertTrue(notice.contains(LinkDownloadError.interrupted.reason), notice)
        XCTAssertFalse(links.isBusy, "nothing was downloaded")
    }

    /// A link marked attempted in this same run is downloading, not
    /// interrupted: it is neither dropped nor queued again.
    func testALinkDownloadingInThisRunIsNotTakenForInterrupted() throws {
        let inbox = inbox()
        _ = try inbox.add("https://files.example/map.wad").get()
        let pickup = pickup(inbox)
        var calls: [Call] = []

        pickup.pickUp(into: { calls.append(Call(urls: $0, extras: $1, finish: $2)) })
        XCTAssertEqual(pickup.pickUp(into: { calls.append(Call(urls: $0, extras: $1, finish: $2)) }), false)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(filesInInbox().count, 1)
    }

    // MARK: Staged files a killed writer left

    /// A `.writing-` file older than a few minutes is what an extension
    /// killed between writing and renaming leaves; the pick-up sweeps it.
    /// A fresh one may be another writer's, mid-write, and is left alone.
    func testAStaleStagedFileIsSweptAndAFreshOneIsLeft() throws {
        let clock = Clock()
        let inbox = inbox(clock)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        let nowMillis = Int64(clock.now.timeIntervalSince1970 * 1000)
        let staleMillis = nowMillis - Int64((PendingLinkInbox.staleStagingAge + 60) * 1000)
        let stale = "\(PendingLinkInbox.stagingPrefix)\(staleMillis)-A"
        let fresh = "\(PendingLinkInbox.stagingPrefix)\(nowMillis - 1000)-B"
        for name in [stale, fresh] { try Data("{}".utf8).write(to: inboxDir.appendingPathComponent(name)) }

        _ = inbox.waiting()

        let left = try FileManager.default.contentsOfDirectory(atPath: inboxDir.path)
        XCTAssertFalse(left.contains(stale), "the stale staged file was not swept")
        XCTAssertTrue(left.contains(fresh), "a staged file still being written was swept")
    }

    // MARK: A link waits until the shelf can show it

    /// With something presented over the shelf, or a game running, nothing
    /// is taken or downloaded: the link waits in the inbox.
    func testNothingIsPickedUpWhileTheShelfCannotShowIt() throws {
        let inbox = inbox()
        _ = try inbox.add("https://files.example/map.wad").get()
        var calls = 0
        var started = 0

        let result = pickup(inbox, canPresent: { false })
            .pickUp(into: { _, _, _ in calls += 1 }, onStarted: { started += 1 })

        XCTAssertNil(result)
        XCTAssertEqual(calls, 0, "nothing is downloaded unseen")
        XCTAssertEqual(started, 0)
        XCTAssertEqual(filesInInbox().count, 1)
    }

    /// Once whatever was in the way is gone, the waiting pick-up takes the
    /// link and asks the shelf to show its download.
    func testAWaitingPickUpTakesTheLinkOnceTheShelfIsClear() async throws {
        let inbox = inbox()
        _ = try inbox.add("https://files.example/map.wad").get()
        var clear = false
        let pickup = pickup(inbox, canPresent: { clear })
        var calls: [Call] = []
        var started = 0

        pickup.pickUpWhenClear(into: { calls.append(Call(urls: $0, extras: $1, finish: $2)) },
                               onStarted: { started += 1 })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(pickup.isWaiting)
        XCTAssertEqual(calls.count, 0, "held while the shelf is covered")

        clear = true
        let deadline = Date().addingTimeInterval(5)
        while calls.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertEqual(calls.first?.urls.map(\.lastPathComponent), ["map.wad"])
        XCTAssertEqual(started, 1)
        while pickup.isWaiting, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(pickup.isWaiting, "it stops looking once it has the link")
    }

    func testThereIsNothingToWaitForWhenNoLinkIsWaiting() {
        let pickup = pickup(canPresent: { false })
        pickup.pickUpWhenClear(into: { _, _, _ in }, onStarted: {})
        XCTAssertFalse(pickup.isWaiting, "no polling for an empty inbox")
    }

    /// A share that arrives during a game session waits until the player is
    /// back on the shelf: the shelf's own check says no while a session
    /// runs, and while the app is not active.
    func testALinkWaitsWhileAGameSessionRuns() throws {
        let inbox = inbox()
        _ = try inbox.add("https://files.example/map.wad").get()
        let root = UIViewController()
        let pickup = pickup(inbox, canPresent: { SharedLinkPickup.shelfCanPresent(engineRunning: EngineSession.isRunning,
                                                                                  appActive: true, root: root) })
        var calls = 0

        EngineSession.setRunningForTesting(true)
        XCTAssertNil(pickup.pickUp(into: { _, _, _ in calls += 1 }))
        EngineSession.setRunningForTesting(false)
        XCTAssertEqual(pickup.pickUp(into: { _, _, _ in calls += 1 }), true)
        XCTAssertEqual(calls, 1)
    }

    func testTheShelfCannotShowALinkWhileInactiveOrWithNoWindow() {
        let root = UIViewController()
        XCTAssertTrue(SharedLinkPickup.shelfCanPresent(engineRunning: false, appActive: true, root: root))
        XCTAssertFalse(SharedLinkPickup.shelfCanPresent(engineRunning: true, appActive: true, root: root))
        XCTAssertFalse(SharedLinkPickup.shelfCanPresent(engineRunning: false, appActive: false, root: root))
        XCTAssertFalse(SharedLinkPickup.shelfCanPresent(engineRunning: false, appActive: true, root: nil))
    }

    /// A sheet presented from a child controller, as SwiftUI presents from
    /// inside a navigation stack, covers the shelf as much as one presented
    /// from the root.
    func testASheetPresentedAnywhereInTheWindowCoversTheShelf() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        let child = UIViewController()
        root.addChild(child)
        root.view.addSubview(child.view)
        child.didMove(toParent: root)
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }

        XCTAssertFalse(SharedLinkPickup.presentsAnything(root))
        let presented = expectation(description: "presented")
        child.present(UIViewController(), animated: false) { presented.fulfill() }
        wait(for: [presented], timeout: 5)

        XCTAssertTrue(SharedLinkPickup.presentsAnything(root))
        XCTAssertFalse(SharedLinkPickup.shelfCanPresent(engineRunning: false, appActive: true, root: root))
        let dismissed = expectation(description: "dismissed")
        child.dismiss(animated: false) { dismissed.fulfill() }
        wait(for: [dismissed], timeout: 5)
    }

    // MARK: Through the real queue

    /// A link shared twice before Waddle opens is downloaded twice, and the
    /// second is reported as already in the library, in the queue's one
    /// notice, by the dedupe every import goes through. Both leave the
    /// inbox once the queue has ended.
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

        XCTAssertEqual(pickup(inbox).pickUp(into: { links.enqueue($0, extras: $1, onFinish: $2) }), true)
        XCTAssertEqual(filesInInbox().count, 2, "both wait in the inbox while they download")
        let deadline = Date().addingTimeInterval(20)
        while links.isBusy, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(links.isBusy)
        XCTAssertEqual(StubURLProtocol.requestedURLs, [link, link])
        XCTAssertEqual(try library.allWADs().map(\.filename), ["map.wad"])
        let notice = try XCTUnwrap(notices.current)
        XCTAssertTrue(notice.contains("1 already in library"), notice)
        XCTAssertEqual(filesInInbox(), [], "both are removed once the queue has told its notice")
    }

    /// A download that fails is told with its reason, and only then leaves
    /// the inbox.
    func testAFailedDownloadLeavesTheInboxOnceItsReasonIsTold() async throws {
        let link = "https://files.example/gone.wad"
        StubURLProtocol.set(.respond(status: 404, headers: [:], body: Data()), for: link)
        let inbox = inbox()
        _ = try inbox.add(link).get()
        let notices = ImportNotices()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Game.self, configurations: config)
        let store = WADStore(directory: tmp.appendingPathComponent("WADs", isDirectory: true))
        let library = LibraryService(context: ModelContext(container), store: store)
        let importer = ImportService(library: library, store: store, notices: notices,
                                     usage: UsageStore(directory: tmp.appendingPathComponent("Diagnostics",
                                                                                             isDirectory: true)))
        var downloader = LinkDownloader()
        downloader.directory = tmp.appendingPathComponent("LinkDownloads", isDirectory: true)
        downloader.makeConfiguration = { StubURLProtocol.configuration() }
        let links = LinkImport(importer: importer, downloader: downloader, notices: notices)

        pickup(inbox).pickUp(into: { links.enqueue($0, extras: $1, onFinish: $2) })
        let deadline = Date().addingTimeInterval(20)
        while links.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertEqual(notices.current, "Import failed: \(LinkDownloadError.httpStatus(404).reason)")
        XCTAssertEqual(filesInInbox(), [])
    }
}

/// An array several threads append to.
private final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []
    func append(_ element: Element) { lock.withLock { storage.append(element) } }
    var values: [Element] { lock.withLock { storage } }
}
