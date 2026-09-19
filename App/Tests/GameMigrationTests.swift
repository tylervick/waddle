import SwiftData
import XCTest
@testable import Waddle

/// Spec §5: the one-time launch step that turns IWAD rows into `Game`s. Ids
/// are reused so no `Documents/Saves/<id>/` moves.
@MainActor
final class GameMigrationTests: XCTestCase {
    var service: LibraryService!
    var context: ModelContext!
    var tmp: URL!
    var defaults: UserDefaults!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Game.self, configurations: config)
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
    private func legacyIWAD(_ filename: String, displayName: String? = nil, bundled: Bool = false) throws -> WADFile {
        let wad = WADFile(filename: filename,
                          displayName: displayName ?? (filename as NSString).deletingPathExtension,
                          kindRaw: WADKind.iwad.rawValue, sha1: UUID().uuidString,
                          gameFamilyRaw: GameFamily.doom2.rawValue, isBundled: bundled)
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

    func testIWADRowBecomesABaseGameWithTheSameId() throws {
        let wad = try legacyIWAD("doom2.wad")

        try service.migrateToGames(defaults: defaults)

        let game = try XCTUnwrap(try service.game(id: wad.id))
        XCTAssertEqual(game.id, wad.id)
        XCTAssertTrue(game.isBaseGame)
        XCTAssertEqual(game.baseID, wad.id)
        XCTAssertEqual(game.name, "doom2")
        XCTAssertFalse(game.isHidden, "legacy flags no longer carry over (plan 4, accepted)")
        XCTAssertNil(game.lastPlayed, "legacy flags no longer carry over (plan 4, accepted)")
        XCTAssertNil(game.schemeOverrideRaw, "legacy flags no longer carry over (plan 4, accepted)")
        XCTAssertEqual(try service.games().count, 1)
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
        // Delete the migrated game, then relaunch: the legacy IWAD row is
        // still there and would be re-migrated if anything but the flag
        // were what stopped a second run (the per-id guard can't catch
        // this, since the id it would check no longer exists).
        let game = try XCTUnwrap(try service.game(id: wad.id))
        context.delete(game)
        try context.save()
        try service.migrateToGames(defaults: defaults)
        XCTAssertTrue(try service.games().isEmpty,
                      "the flag, not the id guard, must stop a second run — the legacy IWAD row is still there and would be re-migrated otherwise")
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
        let wad = try legacyIWAD("doom2.wad")
        context.insert(Game.baseGame(for: wad))
        try context.save()
        try service.migrateToGames(defaults: defaults)
        XCTAssertEqual(try service.games().count, 1)
    }

    /// The upgrade path end to end, in the order `WaddleApp` runs it:
    /// migration, then seeder. Every bundled row must get its own base game
    /// and the seeder must find them and add nothing.
    func testUpgradeOrderMakesOneBaseGamePerBundledRowAndAddsNoDuplicate() throws {
        // An old install: bundled rows exist (seeded by the old build).
        let old = LibraryService(context: context, store: WADStore(directory: tmp))
        try old.seedBundledContentIfNeeded()   // new seeder — also makes games; undo that to fake an old store
        for game in try old.games() { context.delete(game) }
        try context.save()
        let bundledIDs = Set(try old.allWADs().filter(\.isBundled).map(\.id))

        try service.migrateToGames(defaults: defaults)
        try service.seedBundledContentIfNeeded()

        let games = try service.games()
        XCTAssertEqual(games.count, 2, "one base game per bundled row, no duplicate")
        XCTAssertTrue(games.allSatisfy(\.isBaseGame))
        XCTAssertEqual(Set(games.map(\.id)), bundledIDs)
        XCTAssertTrue(games.allSatisfy { !$0.isHidden })
    }
}
