import XCTest
@testable import WADdle

final class BreadcrumbLogTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("breadcrumbs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testEventsAreAppendedInOrderWithTimestamps() {
        let log = BreadcrumbLog(directory: tmp)
        log.record(.appLaunch, at: Date(timeIntervalSince1970: 0))
        log.record(.scenePhase(from: "active", to: "background"))
        log.record(.sessionBegin(name: "Freedoom Phase 1"))
        log.record(.sessionEnd(exitCode: 0, engineMessage: nil))

        let lines = BreadcrumbLog.lines(in: tmp)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "1970-01-01T00:00:00Z app launch",
            "every line is stamped, and the stamp leads -- the trail is read chronologically")
        XCTAssertTrue(lines[1].hasSuffix("scene: active -> background"), lines[1])
        XCTAssertTrue(lines[2].hasSuffix("session begin: Freedoom Phase 1"), lines[2])
        XCTAssertTrue(lines[3].hasSuffix("session end: exit 0"), lines[3])
    }

    func testTrailSpansInstancesRatherThanRestarting() {
        BreadcrumbLog(directory: tmp).record(.appLaunch)
        BreadcrumbLog(directory: tmp).record(.appLaunch)

        XCTAssertEqual(BreadcrumbLog.lines(in: tmp).count, 2,
            "a relaunch must extend the trail -- spanning launches is the whole point")
    }

    func testStuckAlertLeavesAPresentedLineWithNoDismissal() {
        let log = BreadcrumbLog(directory: tmp)
        log.record(.alertPresented(title: "Couldn't run this preset"))
        log.record(.appLaunch)

        let lines = BreadcrumbLog.lines(in: tmp)
        XCTAssertTrue(lines[0].hasSuffix("alert presented: Couldn't run this preset"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("app launch"),
            "presented -> launch with no dismissal in between IS the stuck-UI evidence")
        XCTAssertFalse(lines.contains { $0.contains("alert dismissed") })
    }

    func testSessionEndCarriesTheEngineMessageOnlyWhenTheExitIsNonzero() {
        let log = BreadcrumbLog(directory: tmp)
        log.record(.sessionEnd(exitCode: 0, engineMessage: "stale text from a prior run"))
        log.record(.sessionEnd(exitCode: -1, engineMessage: "W_GetNumForName: HELP not found"))

        let lines = BreadcrumbLog.lines(in: tmp)
        XCTAssertFalse(lines[0].contains("stale text"),
            "the errmsg buffer survives a clean exit; reporting it would invent a failure")
        XCTAssertTrue(lines[1].hasSuffix("session end: exit -1 | W_GetNumForName: HELP not found"),
                      lines[1])
    }

    func testFilesystemPathsAreReducedToNames() {
        let log = BreadcrumbLog(directory: tmp)
        log.record(.sessionEnd(
            exitCode: -1,
            engineMessage: "Failed to load /var/mobile/Containers/Data/Application/AB-CD/Documents/WADs/private.wad"))

        let line = BreadcrumbLog.lines(in: tmp)[0]
        XCTAssertFalse(line.contains("/"),
            "names only, no paths -- the same envelope info.txt keeps")
        XCTAssertTrue(line.hasSuffix("Failed to load private.wad"), line)
    }

    func testNewlinesInAValueCannotForgeExtraEvents() {
        let log = BreadcrumbLog(directory: tmp)
        log.record(.sessionBegin(name: "Nuts\nalert dismissed"))

        let lines = BreadcrumbLog.lines(in: tmp)
        XCTAssertEqual(lines.count, 1, "one event is one line, whatever the value contains")
        XCTAssertTrue(lines[0].hasSuffix("session begin: Nuts alert dismissed"), lines[0])
    }

    func testARunawayEngineMessageCannotEvictTheRestOfTheTrail() {
        let log = BreadcrumbLog(directory: tmp)
        log.record(.appLaunch)
        log.record(.sessionEnd(exitCode: -1,
                               engineMessage: String(repeating: "x", count: 5_000)))

        let lines = BreadcrumbLog.lines(in: tmp)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("app launch"),
            "the launch line must survive a message that would otherwise fill the buffer")
        XCTAssertLessThan(lines[1].count, 400, "one event stays bounded")
    }

    func testOldestLinesAreEvictedOnceTheCapIsReached() throws {
        let log = BreadcrumbLog(directory: tmp, maxBytes: 400)
        for index in 0..<200 {
            log.record(.sessionBegin(name: "run \(index)"))
        }

        let size = try Data(contentsOf: log.fileURL).count
        XCTAssertLessThanOrEqual(size, 400, "the ring buffer holds its cap")
        let lines = BreadcrumbLog.lines(in: tmp)
        XCTAssertTrue(lines.last!.hasSuffix("session begin: run 199"),
            "eviction comes off the front: the newest events are the ones worth keeping")
        XCTAssertFalse(lines.contains { $0.hasSuffix("session begin: run 0") },
            "the oldest events are gone")
    }

    func testNothingRecordedMeansNothingToBundle() {
        XCTAssertEqual(BreadcrumbLog.breadcrumbFiles(in: tmp), [],
            "a fresh install with no trail must still export down to info.txt alone")
        XCTAssertEqual(BreadcrumbLog.lines(in: tmp), [])
    }

    func testRecordedFileIsOfferedToTheExporter() {
        BreadcrumbLog(directory: tmp).record(.appLaunch)

        XCTAssertEqual(BreadcrumbLog.breadcrumbFiles(in: tmp).map(\.lastPathComponent),
                       [BreadcrumbLog.fileName])
    }
}
