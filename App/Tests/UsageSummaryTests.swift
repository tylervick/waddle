import SwiftData
import UIKit
import XCTest
import ZIPFoundation
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

    private func start(_ s: UsageStore, _ bucket: UsageGameBucket = .imported,
                       scheme: TouchControlScheme = .classic, controller: Bool = false,
                       orientation: UsageOrientation = .landscape) {
        s.recordSessionStart(bucket: bucket, scheme: scheme,
                             controllerConnected: controller, orientation: orientation)
    }

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
        start(s, .freedoomPhase1)
        s.recordSessionEnd(bucket: .freedoomPhase1, exitCode: 0, playTime: 90)

        let summary = s.summary()
        XCTAssertEqual(summary.sessionsStarted, 1)
        XCTAssertEqual(summary.sessionsClean, 1)
        XCTAssertEqual(summary.sessionsFailed, 0)
        XCTAssertEqual(summary.playMinutesTotal, 1.5)
        XCTAssertEqual(summary.sessionsByGame.freedoomPhase1.sessions, 1)
        XCTAssertEqual(summary.sessionsByGame.freedoomPhase1.minutes, 1.5)
        XCTAssertEqual(summary.sessionsByGame.imported, .init())
    }

    func testAFailedSessionCountsAsStartedAndFailed() {
        let s = store()
        start(s)
        s.recordSessionEnd(bucket: .imported, exitCode: -1, playTime: 2)

        let summary = s.summary()
        XCTAssertEqual(summary.sessionsStarted, 1)
        XCTAssertEqual(summary.sessionsClean, 0)
        XCTAssertEqual(summary.sessionsFailed, 1)
    }

    func testAStartWithNoEndIsVisibleAsAnUnendedSession() {
        let s = store()
        start(s, scheme: .modern)
        let summary = s.summary()
        XCTAssertEqual(summary.sessionsStarted, 1,
                       "counted before the engine runs, so a crash still leaves the start")
        XCTAssertEqual(summary.sessionsClean + summary.sessionsFailed
                       + summary.sessionsEndedWhileInactive, 0)
    }

    func testControlSchemeAndControllerAreCountedAtSessionStart() {
        let s = store()
        start(s, scheme: .classic)
        start(s, scheme: .modern)
        start(s, scheme: .modern, controller: true, orientation: .portrait)

        let schemes = s.summary().sessionsByControlScheme
        XCTAssertEqual(schemes.classic, 1)
        XCTAssertEqual(schemes.modern, 2)
        XCTAssertEqual(schemes.gameController, 1,
                       "a controller is counted on top of the touch scheme in force")
        let orientations = s.summary().sessionsByOrientation
        XCTAssertEqual(orientations.landscape, 2)
        XCTAssertEqual(orientations.portrait, 1)
    }

    func testPlayMinutesAddUpPerBucketAndInTotal() {
        let s = store()
        for (bucket, seconds) in [(UsageGameBucket.imported, 60.0), (.freedoomPhase2, 30.0),
                                  (.imported, 6.0)] {
            start(s, bucket)
            s.recordSessionEnd(bucket: bucket, exitCode: 0, playTime: seconds)
        }
        let summary = s.summary()
        XCTAssertEqual(summary.sessionsByGame.imported.sessions, 2)
        XCTAssertEqual(summary.sessionsByGame.imported.minutes, 1.1)
        XCTAssertEqual(summary.sessionsByGame.freedoomPhase2.minutes, 0.5)
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

    // MARK: Buckets, never names

    func testBucketsAreFixedByTheBundledBaseAndNothingElse() {
        XCTAssertEqual(UsageGameBucket.of(baseFilename: "freedoom1.wad", baseIsBundled: true,
                                          hasFiles: false), .freedoomPhase1)
        XCTAssertEqual(UsageGameBucket.of(baseFilename: "freedoom2.wad", baseIsBundled: true,
                                          hasFiles: false), .freedoomPhase2)
        XCTAssertEqual(UsageGameBucket.of(baseFilename: "freedoom2.wad", baseIsBundled: true,
                                          hasFiles: true), .imported,
                       "a map set over Freedoom is something the user brought")
        XCTAssertEqual(UsageGameBucket.of(baseFilename: "freedoom1.wad", baseIsBundled: false,
                                          hasFiles: false), .imported,
                       "an imported file that happens to share the name is not the bundled game")
        XCTAssertEqual(UsageGameBucket.of(baseFilename: nil, baseIsBundled: false,
                                          hasFiles: true), .imported)
    }

    // MARK: Active time, checkpoints on resign, and kills

    @MainActor
    func testBackgroundTimeIsNotPlayTime() {
        let s = store()
        let center = NotificationCenter()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let session = UsageSession(store: s, bucket: .imported, scheme: .classic,
                                   controllerConnected: false, orientation: .landscape,
                                   center: center, now: { clock })
        clock += 120
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        clock += 8 * 3600   // left overnight
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        clock += 60
        session.end(exitCode: 0)

        let summary = s.summary()
        XCTAssertEqual(summary.playMinutesTotal, 3, "two minutes before, one after; none overnight")
        XCTAssertEqual(summary.sessionsByGame.imported.minutes, 3)
        XCTAssertEqual(summary.sessionsClean, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.inactiveMarkerURL.path))
    }

    @MainActor
    func testResigningActiveCheckpointsTheMinutesToDisk() {
        let s = store()
        let center = NotificationCenter()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let session = UsageSession(store: s, bucket: .freedoomPhase1, scheme: .classic,
                         controllerConnected: false, orientation: .landscape,
                         center: center, now: { clock })
        clock += 300
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        withExtendedLifetime(session) {}

        // Read back through a fresh store, as the next process would.
        let summary = UsageStore(directory: tmp).summary()
        XCTAssertEqual(summary.playMinutesTotal, 5)
        XCTAssertEqual(summary.sessionsByGame.freedoomPhase1.minutes, 5)
    }

    @MainActor
    func testAProcessKilledInTheBackgroundIsCountedAsEndedThereNotAsACrash() {
        let s = store()
        let center = NotificationCenter()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let session = UsageSession(store: s, bucket: .imported, scheme: .classic,
                         controllerConnected: false, orientation: .landscape,
                         center: center, now: { clock })
        clock += 90
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        withExtendedLifetime(session) {}
        // The process ends here: no foreground, no end(). Next launch:
        UsageStore(directory: tmp).recordLaunch(version: "1.6 (1)")

        let summary = s.summary()
        XCTAssertEqual(summary.sessionsStarted, 1)
        XCTAssertEqual(summary.sessionsEndedWhileInactive, 1)
        XCTAssertEqual(summary.sessionsClean + summary.sessionsFailed, 0)
        XCTAssertEqual(summary.playMinutesTotal, 1.5, "the minutes survived the kill")
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.inactiveMarkerURL.path),
                       "settled once, not again at every later launch")
        UsageStore(directory: tmp).recordLaunch(version: "1.6 (1)")
        XCTAssertEqual(s.summary().sessionsEndedWhileInactive, 1)
    }

    @MainActor
    func testACrashWhileActiveStaysAStartWithNoEnd() {
        let s = store()
        let center = NotificationCenter()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let session = UsageSession(store: s, bucket: .imported, scheme: .classic,
                         controllerConnected: false, orientation: .landscape,
                         center: center, now: { clock })
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        clock += 10
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        withExtendedLifetime(session) {}
        // Crashes in the foreground. Next launch:
        UsageStore(directory: tmp).recordLaunch(version: "1.6 (1)")

        let summary = s.summary()
        XCTAssertEqual(summary.sessionsStarted, 1)
        XCTAssertEqual(summary.sessionsEndedWhileInactive, 0,
                       "becoming active again cleared the marker")
        XCTAssertEqual(summary.sessionsClean + summary.sessionsFailed, 0)
    }

    /// The commonest kill: mid-game, swipe up to the app switcher, flick the
    /// card away. The app resigns active and is never told it entered the
    /// background, yet the engine paused at the resign.
    @MainActor
    func testAKillFromTheAppSwitcherKeepsTheMinutesAndIsNotACrash() {
        let s = store()
        let center = NotificationCenter()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let session = UsageSession(store: s, bucket: .imported, scheme: .classic,
                                   controllerConnected: false, orientation: .landscape,
                                   center: center, now: { clock })
        clock += 240
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        withExtendedLifetime(session) {}
        // Flicked away in the switcher: no background, no end(). Next launch:
        UsageStore(directory: tmp).recordLaunch(version: "1.6 (1)")

        let summary = s.summary()
        XCTAssertEqual(summary.playMinutesTotal, 4, "the stretch before the switcher survived")
        XCTAssertEqual(summary.sessionsEndedWhileInactive, 1)
        XCTAssertEqual(summary.sessionsClean + summary.sessionsFailed, 0)
    }

    /// The switcher, Control Center, Notification Center, a call banner or
    /// Siri: the app is inactive, the engine is paused, and it is not play.
    @MainActor
    func testInactiveTimeIsNotPlayTime() {
        let s = store()
        let center = NotificationCenter()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let session = UsageSession(store: s, bucket: .imported, scheme: .classic,
                                   controllerConnected: false, orientation: .landscape,
                                   center: center, now: { clock })
        clock += 60
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        clock += 600   // Control Center left open
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        clock += 60
        session.end(exitCode: 0)

        XCTAssertEqual(s.summary().playMinutesTotal, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.inactiveMarkerURL.path))
    }

    @MainActor
    func testASessionStartedWhileInactiveCountsOnlyOnceActive() {
        let s = store()
        let center = NotificationCenter()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let session = UsageSession(store: s, bucket: .imported, scheme: .classic,
                                   controllerConnected: false, orientation: .landscape,
                                   startsActive: false, center: center, now: { clock })
        clock += 300
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        clock += 120
        session.end(exitCode: 0)

        XCTAssertEqual(s.summary().playMinutesTotal, 2)
    }

    @MainActor
    func testASessionThatEndedStopsListening() {
        let s = store()
        let center = NotificationCenter()
        let session = UsageSession(store: s, bucket: .imported, scheme: .classic,
                                   controllerConnected: false, orientation: .landscape,
                                   center: center)
        session.end(exitCode: 0)
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.inactiveMarkerURL.path),
                       "a later resign outside any session must not mark one")
    }

    // MARK: Persistence

    func testCountsPersistAcrossAFreshStoreInstance() {
        store().recordLaunch(version: "1.5 (295)")
        start(store(), scheme: .modern, controller: true)
        store().recordSessionEnd(bucket: .imported, exitCode: 0, playTime: 120)

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

    func testAnOlderFileKeyedByGameNameLosesTheNamesOnTheNextWrite() throws {
        try Data(#"{"launches": 2, "sessions_by_game": {"private_thing": {"sessions": 3, "minutes": 9}}}"#.utf8)
            .write(to: store().fileURL)
        store().recordLaunch(version: "1.6 (1)")
        let text = String(decoding: try Data(contentsOf: store().fileURL), as: UTF8.self)
        XCTAssertFalse(text.contains("private_thing"), text)
        XCTAssertEqual(store().summary().launches, 3)
    }

    // MARK: Reset

    func testResetZeroesEverything() {
        let s = store()
        s.recordLaunch(version: "1.5 (295)")
        start(s, scheme: .modern, controller: true)
        s.recordSessionInactive(bucket: .imported, playTime: 600)
        s.recordSessionEnd(bucket: .imported, exitCode: -1, playTime: 600)
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
        start(s, controller: true, orientation: .portrait)
        s.recordSessionEnd(bucket: .imported, exitCode: 0, playTime: 60)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: s.fileURL)) as? [String: Any])
        try UsageKeys.assertExact(object)
        let day = try XCTUnwrap(object["first_seen_day"] as? String)
        XCTAssertNotNil(day.wholeMatch(of: /\d{4}-\d{2}-\d{2}/), "a day, nothing finer: \(day)")
    }

    func testRowsShowEveryCount() {
        var summary = UsageSummary()
        summary.launches = 12
        summary.sessionsEndedWhileInactive = 2
        summary.sessionsByControlScheme.gameController = 3
        summary.sessionsByGame.imported.sessions = 4
        summary.sessionsByGame.imported.minutes = 12.5
        let text = summary.rows.map { "\($0.label): \($0.value)" }
        XCTAssertTrue(text.contains("Launches: 12"))
        XCTAssertTrue(text.contains("Sessions ended while inactive: 2"))
        XCTAssertTrue(text.contains("With a game controller: 3 sessions"))
        XCTAssertTrue(text.contains("Imported games: 4 sessions, 12.5 min"))
        XCTAssertTrue(text.contains("Freedoom Phase 1: 0 sessions, 0.0 min"))
        XCTAssertTrue(text.contains("Diagnostics files shared: 0"))
    }
}

/// The whole vocabulary of `usage.json`, spelled out so a test fails on any
/// key added without a decision (issue #487's field list).
enum UsageKeys {
    static let topLevel: Set<String> = [
        "first_seen_day", "last_seen_day", "app_versions", "launches",
        "sessions_started", "sessions_clean", "sessions_failed", "sessions_ended_while_inactive",
        "play_minutes_total", "sessions_by_control_scheme", "sessions_by_orientation",
        "sessions_by_game", "wads_imported", "games_created", "diagnostics_exports",
    ]
    static let controlScheme: Set<String> = ["classic", "modern", "game_controller"]
    static let orientation: Set<String> = ["portrait", "landscape"]
    static let games: Set<String> = ["freedoom_phase_1", "freedoom_phase_2", "imported"]
    static let gameCounts: Set<String> = ["sessions", "minutes"]

    /// Every level of the file, not only the top.
    static func assertExact(_ object: [String: Any],
                            file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(Set(object.keys), topLevel, file: file, line: line)
        XCTAssertEqual(Set(try XCTUnwrap(object["sessions_by_control_scheme"] as? [String: Any]).keys),
                       controlScheme, file: file, line: line)
        XCTAssertEqual(Set(try XCTUnwrap(object["sessions_by_orientation"] as? [String: Any]).keys),
                       orientation, file: file, line: line)
        let games = try XCTUnwrap(object["sessions_by_game"] as? [String: Any])
        XCTAssertEqual(Set(games.keys), Self.games, file: file, line: line)
        for (bucket, counts) in games {
            XCTAssertEqual(Set(try XCTUnwrap(counts as? [String: Any], bucket).keys),
                           gameCounts, bucket, file: file, line: line)
        }
    }
}

/// The review of pull request 491: a game's name is a file title or text
/// the user typed, so it must never reach the usage counts, and nothing may
/// survive a rename or a delete.
@MainActor
final class UsageNamePrivacyTests: XCTestCase {
    var service: LibraryService!
    var tmp: URL!
    var diagnostics: URL!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Game.self, configurations: config)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        diagnostics = tmp.appendingPathComponent("Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        service = LibraryService(context: ModelContext(container), store: WADStore(directory: tmp))
        service.bundledContentDirectory = try FreedoomFixture.directory()
        try service.seedBundledContentIfNeeded()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func play(_ game: Game, store: UsageStore) {
        let session = UsageSession(store: store, bucket: UsageGameBucket.of(game, in: service),
                                   scheme: .classic, controllerConnected: false,
                                   orientation: .landscape, center: NotificationCenter())
        session.end(exitCode: 0)
    }

    private func exportedText() throws -> String {
        let zip = try DiagnosticsExporter.export(diagnosticsDirectory: diagnostics,
                                                 libraryLines: [])
        let archive = try Archive(url: zip, accessMode: .read)
        var text = ""
        for entry in archive {
            var data = Data()
            _ = try archive.extract(entry, consumer: { data.append($0) })
            text += String(decoding: data, as: UTF8.self)
        }
        return text
    }

    func testAPlayedRenamedThenDeletedImportedGameLeavesNoTraceOfItsNames() throws {
        let usage = UsageStore(directory: diagnostics)
        let wad = try service.registerImported(filename: "private_thing.wad", sha1: "abc123",
                                               kind: "pwad", family: GameFamily.doom2.rawValue,
                                               hasMaps: true)
        let base = try XCTUnwrap(try service.allWADs().first {
            $0.isBundled && $0.filename == "freedoom2.wad"
        })
        let game = try service.createGame(name: "private_thing", baseID: base.id,
                                          fileIDs: [wad.id])
        XCTAssertEqual(UsageGameBucket.of(game, in: service), .imported)
        play(game, store: usage)
        try service.rename(game, to: "My Secret Project")
        play(game, store: usage)

        let whilePresent = String(decoding: try Data(contentsOf: usage.fileURL), as: UTF8.self)
        for name in ["private_thing", "My Secret Project"] {
            XCTAssertFalse(whilePresent.contains(name), "\(name) in usage.json: \(whilePresent)")
        }

        try service.deleteGame(game)
        try service.deleteWAD(wad)
        let exported = try exportedText()
        for name in ["private_thing", "My Secret Project"] {
            XCTAssertFalse(exported.contains(name), "\(name) survived into the export")
        }
        XCTAssertEqual(usage.summary().sessionsByGame.imported.sessions, 2,
                       "still counted, under the bucket")
    }

    func testTheBundledGamesCountUnderTheirFixedNamesEvenWhenRenamed() throws {
        let usage = UsageStore(directory: diagnostics)
        let phase1 = try XCTUnwrap(try service.allWADs().first {
            $0.isBundled && $0.filename == "freedoom1.wad"
        })
        let game = try XCTUnwrap(try service.game(id: phase1.id))
        try service.rename(game, to: "Typed By The User")
        XCTAssertEqual(UsageGameBucket.of(game, in: service), .freedoomPhase1)
        play(game, store: usage)

        let text = String(decoding: try Data(contentsOf: usage.fileURL), as: UTF8.self)
        XCTAssertFalse(text.contains("Typed By The User"), text)
        XCTAssertEqual(usage.summary().sessionsByGame.freedoomPhase1.sessions, 1)
    }
}
