import XCTest
@testable import Waddle

/// Issue #487: the on-device usage counts bundled into the diagnostics export.
final class UsageSummaryTests: XCTestCase {
    var tmp: URL!
    let utc = TimeZone(identifier: "UTC")!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func store() -> UsageStore { UsageStore(directory: tmp) }

    // MARK: Counting

    func testLaunchCountsAndRecordsDaysAndVersionsOldestFirst() {
        let s = store()
        s.recordLaunch(version: "1.4 (282)", at: Date(timeIntervalSince1970: 0), timeZone: utc)
        s.recordLaunch(version: "1.5 (295)", at: Date(timeIntervalSince1970: 86_400 * 3), timeZone: utc)
        s.recordLaunch(version: "1.4 (282)", at: Date(timeIntervalSince1970: 86_400 * 4), timeZone: utc)

        let summary = s.summary()
        XCTAssertEqual(summary.launches, 3)
        XCTAssertEqual(summary.firstSeenDay, "1970-01-01")
        XCTAssertEqual(summary.lastSeenDay, "1970-01-05")
        XCTAssertEqual(summary.appVersions, ["1.4 (282)", "1.5 (295)"],
                       "each version once, in the order first seen")
    }

    func testACleanSessionCountsAsStartedAndClean() {
        let s = store()
        s.recordSessionStart(game: "Freedoom: Phase 1", scheme: .classic,
                             controllerConnected: false, orientation: .landscape)
        s.recordSessionEnd(game: "Freedoom: Phase 1", exitCode: 0, duration: 90)

        let summary = s.summary()
        XCTAssertEqual(summary.sessionsStarted, 1)
        XCTAssertEqual(summary.sessionsClean, 1)
        XCTAssertEqual(summary.sessionsFailed, 0)
        XCTAssertEqual(summary.playMinutesTotal, 1.5)
        XCTAssertEqual(summary.sessionsByGame["Freedoom: Phase 1"]?.sessions, 1)
        XCTAssertEqual(summary.sessionsByGame["Freedoom: Phase 1"]?.minutes, 1.5)
    }

    func testAFailedSessionCountsAsStartedAndFailed() {
        let s = store()
        s.recordSessionStart(game: "Nuts", scheme: .classic,
                             controllerConnected: false, orientation: .portrait)
        s.recordSessionEnd(game: "Nuts", exitCode: -1, duration: 2)

        let summary = s.summary()
        XCTAssertEqual(summary.sessionsStarted, 1)
        XCTAssertEqual(summary.sessionsClean, 0)
        XCTAssertEqual(summary.sessionsFailed, 1)
    }

    func testAStartWithNoEndIsVisibleAsAnUnendedSession() {
        let s = store()
        s.recordSessionStart(game: "Nuts", scheme: .modern,
                             controllerConnected: false, orientation: .portrait)
        let summary = s.summary()
        XCTAssertEqual(summary.sessionsStarted, 1,
                       "counted before the engine runs, so a crash still leaves the start")
        XCTAssertEqual(summary.sessionsClean + summary.sessionsFailed, 0)
    }

    func testControlSchemeAndControllerAreCountedAtSessionStart() {
        let s = store()
        s.recordSessionStart(game: "A", scheme: .classic,
                             controllerConnected: false, orientation: .landscape)
        s.recordSessionStart(game: "A", scheme: .modern,
                             controllerConnected: false, orientation: .landscape)
        s.recordSessionStart(game: "A", scheme: .modern,
                             controllerConnected: true, orientation: .portrait)

        let schemes = s.summary().sessionsByControlScheme
        XCTAssertEqual(schemes.classic, 1)
        XCTAssertEqual(schemes.modern, 2)
        XCTAssertEqual(schemes.gameController, 1,
                       "a controller is counted on top of the touch scheme in force")
        let orientations = s.summary().sessionsByOrientation
        XCTAssertEqual(orientations.landscape, 2)
        XCTAssertEqual(orientations.portrait, 1)
    }

    func testPlayMinutesAddUpPerGameAndInTotal() {
        let s = store()
        for (game, seconds) in [("A", 60.0), ("B", 30.0), ("A", 6.0)] {
            s.recordSessionStart(game: game, scheme: .classic,
                                 controllerConnected: false, orientation: .landscape)
            s.recordSessionEnd(game: game, exitCode: 0, duration: seconds)
        }
        let summary = s.summary()
        XCTAssertEqual(summary.sessionsByGame["A"]?.sessions, 2)
        XCTAssertEqual(summary.sessionsByGame["A"]?.minutes, 1.1)
        XCTAssertEqual(summary.sessionsByGame["B"]?.minutes, 0.5)
        XCTAssertEqual(summary.playMinutesTotal, 1.6)
    }

    func testImportsGamesCreatedAndExportsAreCounted() {
        let s = store()
        var outcome = ImportOutcome()
        outcome.imported = ["a.wad", "b.wad", "c.pk3"]
        outcome.games = ["a", "b"]
        s.recordImport(outcome)
        s.recordGameCreated()
        s.recordExport()
        s.recordExport()

        let summary = s.summary()
        XCTAssertEqual(summary.wadsImported, 3)
        XCTAssertEqual(summary.gamesCreated, 3, "two from the import, one duplicated")
        XCTAssertEqual(summary.diagnosticsExports, 2)
    }

    // MARK: Persistence

    func testCountsPersistAcrossAFreshStoreInstance() {
        store().recordLaunch(version: "1.5 (295)")
        store().recordSessionStart(game: "A", scheme: .modern,
                                   controllerConnected: true, orientation: .landscape)
        store().recordSessionEnd(game: "A", exitCode: 0, duration: 120)

        let summary = UsageStore(directory: tmp).summary()
        XCTAssertEqual(summary.launches, 1)
        XCTAssertEqual(summary.sessionsStarted, 1)
        XCTAssertEqual(summary.sessionsClean, 1)
        XCTAssertEqual(summary.playMinutesTotal, 2)
        XCTAssertEqual(summary.sessionsByControlScheme.gameController, 1)
    }

    func testAMissingFileStartsFromZero() {
        XCTAssertEqual(store().summary(), UsageSummary())
    }

    func testACorruptFileStartsFromZeroAndIsRepairedByTheNextWrite() throws {
        try Data("{not json".utf8).write(to: store().fileURL)
        XCTAssertEqual(store().summary(), UsageSummary())

        store().recordLaunch(version: "1.5 (295)")
        XCTAssertEqual(store().summary().launches, 1)
    }

    func testAFieldMissingFromTheFileReadsAsZeroWithoutLosingTheOthers() throws {
        try Data(#"{"launches": 7, "sessions_by_orientation": {"landscape": 2}}"#.utf8)
            .write(to: store().fileURL)
        let summary = store().summary()
        XCTAssertEqual(summary.launches, 7)
        XCTAssertEqual(summary.sessionsByOrientation.landscape, 2)
        XCTAssertEqual(summary.sessionsByOrientation.portrait, 0)
        XCTAssertEqual(summary.sessionsStarted, 0)
    }

    // MARK: Reset

    func testResetZeroesEverything() {
        let s = store()
        s.recordLaunch(version: "1.5 (295)")
        s.recordSessionStart(game: "A", scheme: .modern,
                             controllerConnected: true, orientation: .landscape)
        s.recordSessionEnd(game: "A", exitCode: -1, duration: 600)
        var outcome = ImportOutcome()
        outcome.imported = ["a.wad"]
        outcome.games = ["a"]
        s.recordImport(outcome)
        s.recordExport()
        XCTAssertNotEqual(s.summary(), UsageSummary())

        s.reset()
        XCTAssertEqual(s.summary(), UsageSummary())
        XCTAssertEqual(UsageStore(directory: tmp).summary(), UsageSummary(),
                       "the zeros are on disk, not only in memory")
    }

    // MARK: Shape

    func testTheFileHasExactlyTheListedKeysAndNoTimeFinerThanADay() throws {
        let s = store()
        s.recordLaunch(version: "1.5 (295)")
        s.recordSessionStart(game: "A", scheme: .classic,
                             controllerConnected: true, orientation: .portrait)
        s.recordSessionEnd(game: "A", exitCode: 0, duration: 60)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: s.fileURL)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "first_seen_day", "last_seen_day", "app_versions", "launches",
            "sessions_started", "sessions_clean", "sessions_failed", "play_minutes_total",
            "sessions_by_control_scheme", "sessions_by_orientation", "sessions_by_game",
            "wads_imported", "games_created", "diagnostics_exports",
        ])
        XCTAssertEqual(Set(try XCTUnwrap(object["sessions_by_control_scheme"] as? [String: Any]).keys),
                       ["classic", "modern", "game_controller"])
        XCTAssertEqual(Set(try XCTUnwrap(object["sessions_by_orientation"] as? [String: Any]).keys),
                       ["portrait", "landscape"])
        let game = try XCTUnwrap((object["sessions_by_game"] as? [String: Any])?["A"] as? [String: Any])
        XCTAssertEqual(Set(game.keys), ["sessions", "minutes"])
        let day = try XCTUnwrap(object["first_seen_day"] as? String)
        XCTAssertNotNil(day.wholeMatch(of: /\d{4}-\d{2}-\d{2}/), "a day, nothing finer: \(day)")
    }

    func testGameNamesAreKeptAsIsNotSnakeCased() throws {
        let s = store()
        s.recordSessionStart(game: "Freedoom: Phase 1", scheme: .classic,
                             controllerConnected: false, orientation: .landscape)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: s.fileURL)) as? [String: Any])
        let games = try XCTUnwrap(object["sessions_by_game"] as? [String: Any])
        XCTAssertEqual(Set(games.keys), ["Freedoom: Phase 1"])
    }

    func testRowsShowEveryCount() {
        var summary = UsageSummary()
        summary.launches = 12
        summary.sessionsByControlScheme.gameController = 3
        summary.sessionsByGame["Nuts"] = {
            var c = UsageSummary.GameCounts(); c.sessions = 4; c.minutes = 12.5; return c
        }()
        let text = summary.rows.map { "\($0.label): \($0.value)" }
        XCTAssertTrue(text.contains("Launches: 12"))
        XCTAssertTrue(text.contains("With a game controller: 3 sessions"))
        XCTAssertTrue(text.contains("Game: Nuts: 4 sessions, 12.5 min"))
        XCTAssertTrue(text.contains("Diagnostics exports: 0"))
    }
}
