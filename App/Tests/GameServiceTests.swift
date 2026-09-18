import SwiftData
import XCTest
@testable import Waddle

/// `LibraryService` over `Game` (spec §§2, 4). Every behaviour the pre-`Game`
/// model had a test for is carried here against `Game`; the plan's Task 8
/// maps each removed test to its row in this file.
@MainActor
final class GameServiceTests: XCTestCase {
    var service: LibraryService!
    var context: ModelContext!
    var tmp: URL!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, Game.self, configurations: config)
        context = ModelContext(container)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        service = LibraryService(context: context, store: WADStore(directory: tmp))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Helpers

    private func iwad(_ name: String = "doom2.wad", sha1: String = UUID().uuidString) throws -> WADFile {
        try service.registerImported(filename: name, sha1: sha1,
                                     kind: WADKind.iwad.rawValue, family: GameFamily.doom2.rawValue)
    }

    private func pwad(_ name: String = "sunlust.wad", hasMaps: Bool = true) throws -> WADFile {
        try service.registerImported(filename: name, sha1: UUID().uuidString,
                                     kind: WADKind.pwad.rawValue, family: GameFamily.doom2.rawValue,
                                     hasMaps: hasMaps)
    }

    /// Real bytes in the store so `deleteWAD` has a file to remove.
    private func backedIWAD(_ name: String) throws -> WADFile {
        try Data(repeating: 0xAB, count: 16).write(to: tmp.appendingPathComponent(name))
        return try iwad(name)
    }

    private func writeSave(forKey key: UUID) throws -> URL {
        let dir = LibraryService.savesDirectory(forGameID: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try Data("save".utf8).write(to: dir.appendingPathComponent("woofsav0.dsg"))
        return dir
    }

    // MARK: Base games arrive with their files

    func testRegisteringAnIWADCreatesItsBaseGameUnderTheIWADsId() throws {
        let wad = try iwad()
        let game = try XCTUnwrap(try service.game(id: wad.id))
        XCTAssertTrue(game.isBaseGame)
        XCTAssertEqual(game.baseID, wad.id)
        XCTAssertEqual(game.name, wad.displayName)
    }

    func testRegisteringAPWADCreatesNoGame() throws {
        // Pairing a map set into a game is plan 3; until then a PWAD is a file.
        _ = try pwad()
        XCTAssertTrue(try service.games().isEmpty)
    }

    func testSeederCreatesOneBaseGamePerBundledIWAD() throws {
        try service.seedBundledContentIfNeeded()
        try service.seedBundledContentIfNeeded()   // idempotent
        XCTAssertEqual(try service.allWADs().filter(\.isBundled).map(\.filename).sorted(),
                       ["freedoom1.wad", "freedoom2.wad"])
        let games = try service.games()
        XCTAssertEqual(games.map(\.name).sorted(), ["Freedoom Phase 1", "Freedoom Phase 2"])
        for game in games {
            XCTAssertTrue(game.isBaseGame)
            XCTAssertEqual(game.id, game.baseID)
        }
    }

    /// The load-bearing case from the launcher spec §4, now on `Game`: a hidden
    /// base game still exists, so the seeder must leave it exactly as it found
    /// it — same id, still hidden, no duplicate (spec §4.5).
    func testSeederLeavesAHiddenBaseGameAlone() throws {
        try service.seedBundledContentIfNeeded()
        let phase1 = try XCTUnwrap(try service.games().first { $0.name == "Freedoom Phase 1" })
        let originalID = phase1.id
        try service.hide(phase1)

        try service.seedBundledContentIfNeeded()

        let games = try service.games()
        XCTAssertEqual(games.count, 2, "a hidden base game must not be re-seeded as a duplicate")
        let after = try XCTUnwrap(games.first { $0.name == "Freedoom Phase 1" })
        XCTAssertEqual(after.id, originalID, "a fresh id would orphan the game's saves")
        XCTAssertTrue(after.isHidden, "the seeder must not unhide what the player hid")
        XCTAssertFalse(try service.shelfGames().contains { $0.id == originalID })
    }

    // MARK: Queries

    func testBaseGamesListsEveryIWADBundledFirstThenByTitleIncludingHidden() throws {
        try service.seedBundledContentIfNeeded()
        let mine = try iwad("DOOM2.WAD")
        try service.hide(try XCTUnwrap(try service.game(id: mine.id)))
        XCTAssertEqual(try service.baseGames().map(\.filename), ["freedoom1.wad", "freedoom2.wad", "DOOM2.WAD"],
                       "the base picker is over installed IWADs (spec §3.2); hiding is a shelf matter")
    }

    func testBaseGamesReturnsOnlyIWADs() throws {
        let base = try iwad()
        _ = try pwad()
        XCTAssertEqual(try service.baseGames().map(\.id), [base.id])
    }

    func testGamesSortMostRecentlyPlayedFirstThenNewestCreated() throws {
        let base = try iwad()
        let old = try service.createGame(name: "Old", baseID: base.id, fileIDs: [])
        let recent = try service.createGame(name: "Recent", baseID: base.id, fileIDs: [])
        // Deviation from brief: the brief's dates here were `Date(timeIntervalSince1970:
        // 100/200)` — 1970, long before `base`'s real `createdAt: Date = .now` — so the
        // never-played base game's fallback sort key was numerically the *largest* of
        // the three and it sorted first, not last, failing this test regardless of a
        // correct `games()` (verified against `LibraryServiceTests.testAllLoadoutsSortsMostRecentFirst`'s
        // identical comparator shape). These two dates are moved to just after "now" so
        // both played games' `lastPlayed` outrank `base.createdAt` as the comment intends.
        try service.markPlayed(old, at: Date().addingTimeInterval(100))
        try service.markPlayed(recent, at: Date().addingTimeInterval(200))
        // The never-played base game sorts by createdAt — behind both played games.
        XCTAssertEqual(try service.games().map(\.name), ["Recent", "Old", base.displayName])
    }

    func testShelfGamesExcludesHiddenAndHiddenGamesListsThem() throws {
        let base = try iwad()
        let baseGame = try XCTUnwrap(try service.game(id: base.id))
        let mod = try service.createGame(name: "Sunlust", baseID: base.id, fileIDs: [])
        try service.hide(mod)
        XCTAssertEqual(try service.shelfGames().map(\.id), [baseGame.id])
        XCTAssertEqual(try service.hiddenGames().map(\.id), [mod.id])
        try service.restore(mod)
        XCTAssertEqual(Set(try service.shelfGames().map(\.id)), [baseGame.id, mod.id])
        XCTAssertTrue(try service.hiddenGames().isEmpty)
    }

    func testHideKeepsTheRowAndItsSaves() throws {
        let base = try iwad()
        let game = try XCTUnwrap(try service.game(id: base.id))
        let dir = try writeSave(forKey: game.id)
        try service.hide(game)
        XCTAssertNotNil(try service.game(id: game.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func testGamesUsingFindsBaseAndFileReferences() throws {
        let base = try iwad()
        let map = try pwad()
        let other = try pwad("other.wad")
        let modded = try service.createGame(name: "Sunlust", baseID: base.id, fileIDs: [map.id])
        XCTAssertEqual(Set(try service.gamesUsing(fileID: base.id).map(\.id)), [base.id, modded.id])
        XCTAssertEqual(try service.gamesUsing(fileID: map.id).map(\.id), [modded.id])
        XCTAssertTrue(try service.gamesUsing(fileID: other.id).isEmpty)
    }

    func testRecentlyPlayedExcludesNeverPlayedAndRespectsLimit() throws {
        let base = try iwad()
        let baseGame = try XCTUnwrap(try service.game(id: base.id))
        let a = try service.createGame(name: "A", baseID: base.id, fileIDs: [])
        _ = try service.createGame(name: "Never", baseID: base.id, fileIDs: [])
        try service.markPlayed(a, at: Date(timeIntervalSince1970: 100))
        try service.markPlayed(baseGame, at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(try service.recentlyPlayed(limit: 10).map(\.id), [baseGame.id, a.id])
        XCTAssertEqual(try service.recentlyPlayed(limit: 1).map(\.id), [baseGame.id])
    }

    // MARK: Mutations

    func testCreateGameKeepsFileOrderAndIsNotABaseGame() throws {
        let base = try iwad()
        let a = try pwad("a.wad"), b = try pwad("b.wad")
        let game = try service.createGame(name: "Ordered", baseID: base.id, fileIDs: [b.id, a.id], complevel: "boom")
        XCTAssertEqual(game.fileIDs, [b.id, a.id])
        XCTAssertEqual(game.complevel, "boom")
        XCTAssertFalse(game.isBaseGame)
        XCTAssertEqual(try service.game(id: game.id)?.name, "Ordered")
    }

    func testMarkPlayedStampsLastPlayed() throws {
        let base = try iwad()
        let game = try XCTUnwrap(try service.game(id: base.id))
        let when = Date(timeIntervalSince1970: 1_000_000)
        try service.markPlayed(game, at: when)
        XCTAssertEqual(try service.game(id: game.id)?.lastPlayed, when)
    }

    func testSchemeOverrideRoundTrips() throws {
        let base = try iwad()
        let game = try XCTUnwrap(try service.game(id: base.id))
        try service.setSchemeOverride(TouchControlScheme.classic.rawValue, for: game)
        XCTAssertEqual(try service.game(id: game.id)?.schemeOverrideRaw, TouchControlScheme.classic.rawValue)
        try service.setSchemeOverride(nil, for: game)
        XCTAssertNil(try service.game(id: game.id)?.schemeOverrideRaw)
    }

    func testDeleteGameRemovesTheRowAndItsSaves() throws {
        let base = try iwad()
        let game = try service.createGame(name: "X", baseID: base.id, fileIDs: [])
        let dir = try writeSave(forKey: game.id)
        try service.deleteGame(game)
        XCTAssertNil(try service.game(id: game.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testDeleteGameRefusesABaseGame() throws {
        let base = try iwad()
        let game = try XCTUnwrap(try service.game(id: base.id))
        XCTAssertThrowsError(try service.deleteGame(game)) {
            XCTAssertEqual($0 as? LibraryError, .cannotDeleteBaseGame)
        }
        XCTAssertNotNil(try service.game(id: base.id))
    }

    // MARK: deleteWAD (spec §4.4)

    func testDeleteWADIsBlockedByAnyOtherGameUsingIt() throws {
        let base = try backedIWAD("doom2.wad")
        let map = try pwad()
        _ = try service.createGame(name: "Sunlust", baseID: base.id, fileIDs: [map.id])
        XCTAssertThrowsError(try service.deleteWAD(map)) {
            XCTAssertEqual($0 as? LibraryError, .wadInUse(["Sunlust"]))
        }
        XCTAssertThrowsError(try service.deleteWAD(base)) {
            XCTAssertEqual($0 as? LibraryError, .wadInUse(["Sunlust"]),
                           "the IWAD's own base game is not a blocker; the modded game is")
        }
        XCTAssertNotNil(try service.wad(id: base.id))
    }

    func testDeleteIWADCascadesToItsOwnBaseGameAndSaves() throws {
        let base = try backedIWAD("doom2.wad")
        let dir = try writeSave(forKey: base.id)
        try service.deleteWAD(base)
        XCTAssertNil(try service.wad(id: base.id))
        XCTAssertNil(try service.game(id: base.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("doom2.wad").path))
    }

    func testDeleteUnusedPWADRemovesFileAndRow() throws {
        try Data(repeating: 1, count: 8).write(to: tmp.appendingPathComponent("spare.wad"))
        let spare = try pwad("spare.wad")
        try service.deleteWAD(spare)
        XCTAssertNil(try service.wad(id: spare.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("spare.wad").path))
    }

    // MARK: Factory state (launcher spec §4)

    func testFactoryStateEndsWithANonBaseGame() throws {
        try service.seedBundledContentIfNeeded()
        XCTAssertTrue(try service.isFactoryState())
        let phase1 = try XCTUnwrap(try service.baseGames().first)
        _ = try service.createGame(name: "Mine", baseID: phase1.id, fileIDs: [])
        XCTAssertFalse(try service.isFactoryState())
    }

    func testFactoryStateEndsWithASaveOnABaseGame() throws {
        try service.seedBundledContentIfNeeded()
        let phase1 = try XCTUnwrap(try service.games().first)
        _ = try writeSave(forKey: phase1.id)
        XCTAssertFalse(try service.isFactoryState())
    }

    func testFactoryStateEndsWithAnImportedFileEvenIfItIsNotAGame() throws {
        try service.seedBundledContentIfNeeded()
        _ = try pwad()
        XCTAssertFalse(try service.isFactoryState())
    }
}
