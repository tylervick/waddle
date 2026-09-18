import SwiftData
import XCTest
@testable import Waddle

/// Spec §5: the one-time launch step that turns IWAD rows and `Loadout`s into
/// `Game`s. Ids are reused so no `Documents/Saves/<id>/` moves.
@MainActor
final class GameMigrationTests: XCTestCase {
    var service: LibraryService!
    var context: ModelContext!
    var tmp: URL!
    var defaults: UserDefaults!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, Game.self, configurations: config)
        context = ModelContext(container)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        service = LibraryService(context: context, store: WADStore(directory: tmp))
        defaults = UserDefaults(suiteName: "migrate-\(UUID().uuidString)")!
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// A pre-`Game` row: inserted directly, because `registerImported` now
    /// creates a base game and this suite needs the shape an old build left.
    private func legacyIWAD(_ filename: String, hidden: Bool = false,
                            scheme: String? = nil, played: Date? = nil) throws -> WADFile {
        let wad = WADFile(filename: filename, displayName: (filename as NSString).deletingPathExtension,
                          kindRaw: WADKind.iwad.rawValue, sha1: UUID().uuidString,
                          gameFamilyRaw: GameFamily.doom2.rawValue)
        wad.isHidden = hidden
        wad.schemeOverrideRaw = scheme
        wad.lastPlayed = played
        context.insert(wad)
        try context.save()
        return wad
    }

    private func legacyPWAD(_ filename: String, bytes: Data? = nil) throws -> WADFile {
        if let bytes { try bytes.write(to: tmp.appendingPathComponent(filename)) }
        let wad = WADFile(filename: filename, displayName: (filename as NSString).deletingPathExtension,
                          kindRaw: WADKind.pwad.rawValue, sha1: UUID().uuidString,
                          gameFamilyRaw: GameFamily.doom2.rawValue)
        context.insert(wad)
        try context.save()
        return wad
    }

    @discardableResult
    private func legacyLoadout(name: String, iwadID: UUID, pwadIDs: [UUID] = [], dehIDs: [UUID] = [],
                               complevel: String? = nil, hidden: Bool = false,
                               scheme: String? = nil, played: Date? = nil,
                               createdAt: Date = .now) throws -> Loadout {
        let loadout = Loadout(name: name, iwadID: iwadID, pwadIDs: pwadIDs, dehIDs: dehIDs,
                              complevel: complevel, createdAt: createdAt)
        loadout.isHidden = hidden
        loadout.schemeOverrideRaw = scheme
        loadout.lastPlayed = played
        context.insert(loadout)
        try context.save()
        return loadout
    }

    func testIWADRowBecomesABaseGameWithTheSameIdAndFields() throws {
        let played = Date(timeIntervalSince1970: 1_234)
        let wad = try legacyIWAD("doom2.wad", hidden: true,
                                 scheme: TouchControlScheme.classic.rawValue, played: played)

        try service.migrateToGames(defaults: defaults)

        let game = try XCTUnwrap(try service.game(id: wad.id))
        XCTAssertTrue(game.isBaseGame)
        XCTAssertEqual(game.baseID, wad.id)
        XCTAssertEqual(game.name, "doom2")
        XCTAssertTrue(game.isHidden)
        XCTAssertEqual(game.schemeOverrideRaw, TouchControlScheme.classic.rawValue)
        XCTAssertEqual(game.lastPlayed, played)
        XCTAssertEqual(try service.games().count, 1)
    }

    func testLoadoutBecomesAGameWithTheSameIdAndOrderedFiles() throws {
        let iwad = try legacyIWAD("doom2.wad")
        let a = try legacyPWAD("a.wad"), b = try legacyPWAD("b.wad")
        let deh = WADFile(filename: "fix.deh", displayName: "fix", kindRaw: WADKind.deh.rawValue,
                          sha1: "d", gameFamilyRaw: GameFamily.unknown.rawValue)
        context.insert(deh)
        let played = Date(timeIntervalSince1970: 5_000)
        let created = Date(timeIntervalSince1970: 4_000)
        let loadout = try legacyLoadout(name: "Stack", iwadID: iwad.id, pwadIDs: [b.id, a.id], dehIDs: [deh.id],
                                        complevel: "mbf21", hidden: true,
                                        scheme: TouchControlScheme.modern.rawValue,
                                        played: played, createdAt: created)

        try service.migrateToGames(defaults: defaults)

        let game = try XCTUnwrap(try service.game(id: loadout.id))
        XCTAssertFalse(game.isBaseGame)
        XCTAssertEqual(game.name, "Stack")
        XCTAssertEqual(game.baseID, iwad.id)
        XCTAssertEqual(game.fileIDs, [b.id, a.id, deh.id], "PWADs in order, then patches")
        XCTAssertEqual(game.complevel, "mbf21")
        XCTAssertTrue(game.isHidden)
        XCTAssertEqual(game.schemeOverrideRaw, TouchControlScheme.modern.rawValue)
        XCTAssertEqual(game.lastPlayed, played)
        XCTAssertEqual(game.createdAt, created)
    }

    func testMigrationLeavesTheLoadoutRowInPlace() throws {
        // Spec §5: the table is a tombstone this release, dropped by a later one.
        let iwad = try legacyIWAD("doom2.wad")
        try legacyLoadout(name: "Keep", iwadID: iwad.id)
        try service.migrateToGames(defaults: defaults)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Loadout>()).count, 1)
    }

    func testMigrationFillsHasMapsFromPresentFilesAndToleratesMissingOnes() throws {
        let withMaps = try legacyPWAD("maps.wad", bytes: makeWAD(magic: "PWAD", lumps: ["MAP01", "THINGS"]))
        let noMaps = try legacyPWAD("gfx.wad", bytes: makeWAD(magic: "PWAD", lumps: ["TITLEPIC"]))
        let gone = try legacyPWAD("gone.wad")

        try service.migrateToGames(defaults: defaults)

        XCTAssertTrue(try XCTUnwrap(try service.wad(id: withMaps.id)).hasMaps)
        XCTAssertFalse(try XCTUnwrap(try service.wad(id: noMaps.id)).hasMaps)
        XCTAssertFalse(try XCTUnwrap(try service.wad(id: gone.id)).hasMaps, "unreadable stays on the default")
        XCTAssertEqual(service.fileStatus(for: gone), .missing)
    }

    func testMigrationRunsOnce() throws {
        let wad = try legacyIWAD("doom2.wad")
        try service.migrateToGames(defaults: defaults)
        // Simulate the player hiding the game after migration, then a relaunch.
        let game = try XCTUnwrap(try service.game(id: wad.id))
        try service.hide(game)
        try service.migrateToGames(defaults: defaults)
        XCTAssertEqual(try service.games().count, 1)
        XCTAssertTrue(try XCTUnwrap(try service.game(id: wad.id)).isHidden,
                      "a second run must not rewrite the game from the legacy fields")
    }

    func testMigrationIsANoOpOnAFreshStore() throws {
        try service.migrateToGames(defaults: defaults)
        XCTAssertTrue(try service.games().isEmpty)
        XCTAssertTrue(defaults.bool(forKey: "didMigrateToGames"))
    }

    func testMigrationDoesNotDuplicateAGameThatAlreadyExists() throws {
        // Defensive: if anything created the base game before the migration
        // ran (it must not — see the launch order — but a stale flag or a
        // crash between steps could), the existing game wins.
        let wad = try legacyIWAD("doom2.wad", hidden: true)
        context.insert(Game.baseGame(for: wad))
        try context.save()
        try service.migrateToGames(defaults: defaults)
        XCTAssertEqual(try service.games().count, 1)
    }

    /// The upgrade path end to end, in the order `WaddleApp` runs it: legacy
    /// reconcile, migration, seeder. The bundled rows' games must carry their
    /// hidden flag across and the seeder must find them and add nothing.
    func testUpgradeOrderKeepsABundledGameHiddenAndAddsNoDuplicate() throws {
        // An old install: bundled rows exist (seeded by the old build), one hidden.
        let old = LibraryService(context: context, store: WADStore(directory: tmp))
        try old.seedBundledContentIfNeeded()   // new seeder — also makes games; undo that to fake an old store
        for game in try old.games() { context.delete(game) }
        try context.save()
        let phase1 = try XCTUnwrap(try old.allWADs().first { $0.filename == "freedoom1.wad" })
        phase1.isHidden = true
        try context.save()

        try service.reconcileBundledBaseGameLoadouts(defaults: defaults)
        try service.migrateToGames(defaults: defaults)
        try service.seedBundledContentIfNeeded()

        let games = try service.games()
        XCTAssertEqual(games.count, 2)
        let migrated = try XCTUnwrap(try service.game(id: phase1.id))
        XCTAssertTrue(migrated.isHidden)
        XCTAssertEqual(try service.shelfGames().map(\.name), ["Freedoom Phase 2"])
    }
}
