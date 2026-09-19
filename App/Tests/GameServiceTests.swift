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

    func testRegisteringAPWADWithMapsCreatesAPairedGame() throws {
        // Was "creates no game" before plan 3; pairing itself is covered in
        // detail by the "Import pairing" tests below.
        try service.seedBundledContentIfNeeded()
        let map = try pwad()
        let game = try XCTUnwrap(try service.games().first { $0.fileIDs == [map.id] })
        XCTAssertEqual(game.fileIDs, [map.id])
        let freedoom2 = try XCTUnwrap(try service.allWADs().first { $0.filename == "freedoom2.wad" })
        XCTAssertEqual(game.baseID, freedoom2.id)
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
        // correct `games()` (verified against a test that only ever sets `lastPlayed`,
        // which never hits this mixed-fallback trap — see docs/learnings/
        // epoch-fixture-dates-break-now-fallback-sorts.md). These two dates are moved
        // to just after "now" so both played games' `lastPlayed` outrank `base.createdAt`
        // as the comment intends.
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
        // Add-ons here, not map sets: a map set would pair itself into its own
        // game at import (spec §3.5), muddying what this test is pinning —
        // `gamesUsing` over base/file references on a game created directly.
        let base = try iwad()
        let map = try pwad(hasMaps: false)
        let other = try pwad("other.wad", hasMaps: false)
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
        // An add-on, not a map set: a map set would pair itself into its own
        // game at import (spec §3.5) and be its own blocker.
        let base = try backedIWAD("doom2.wad")
        let map = try pwad(hasMaps: false)
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
        // An add-on, not a map set: a map set would pair itself into its own
        // game at import (spec §3.5) and so never be "unused".
        try Data(repeating: 1, count: 8).write(to: tmp.appendingPathComponent("spare.wad"))
        let spare = try pwad("spare.wad", hasMaps: false)
        try service.deleteWAD(spare)
        XCTAssertNil(try service.wad(id: spare.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("spare.wad").path))
    }

    func testDeleteWADRefusesABundledFileAndKeepsItsGameAndSaves() throws {
        try service.seedBundledContentIfNeeded()
        let wad = try XCTUnwrap(try service.allWADs().first { $0.filename == "freedoom1.wad" })
        let dir = try writeSave(forKey: wad.id)

        XCTAssertThrowsError(try service.deleteWAD(wad)) {
            XCTAssertEqual($0 as? LibraryError, .wadIsBundled)
        }

        XCTAssertNotNil(try service.wad(id: wad.id), "the row must survive")
        XCTAssertNotNil(try service.game(id: wad.id), "its base game must survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "its save must survive")
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

    func testFactoryStateEndsWithAnyImportedFile() throws {
        try service.seedBundledContentIfNeeded()
        _ = try pwad("smooth.wad", hasMaps: false)
        XCTAssertFalse(try service.isFactoryState())
    }

    // MARK: Edits in place (spec §3.2)

    func testRenameSetBaseSetFilesAndSetComplevelPersist() throws {
        let base = try iwad("doom2.wad")
        let other = try iwad("plutonia.wad")
        let a = try pwad("a.wad"), b = try pwad("b.wad")
        let game = try service.createGame(name: "Old", baseID: base.id, fileIDs: [a.id])

        try service.rename(game, to: "New")
        try service.setBase(game, baseID: other.id)
        try service.setFiles(game, fileIDs: [b.id, a.id])
        try service.setComplevel(game, "mbf21")

        let saved = try XCTUnwrap(try service.game(id: game.id))
        XCTAssertEqual(saved.name, "New")
        XCTAssertEqual(saved.baseID, other.id)
        XCTAssertEqual(saved.fileIDs, [b.id, a.id])
        XCTAssertEqual(saved.complevel, "mbf21")
    }

    func testSetBaseRefusesABaseGame() throws {
        let base = try iwad("doom2.wad")
        let other = try iwad("plutonia.wad")
        let game = try XCTUnwrap(try service.game(id: base.id))
        XCTAssertThrowsError(try service.setBase(game, baseID: other.id)) {
            XCTAssertEqual($0 as? LibraryError, .baseGameIsLocked)
        }
        XCTAssertEqual(try service.game(id: base.id)?.baseID, base.id)
    }

    func testSetBaseOnAnUnpairedGamePairsIt() throws {
        let base = try iwad("doom2.wad")
        let game = try service.createGame(name: "Orphan", baseID: nil, fileIDs: [])

        try service.setBase(game, baseID: base.id)

        XCTAssertEqual(try service.game(id: game.id)?.baseID, base.id)
    }

    func testDuplicateCopiesContentsUnderANewIdWithNoSavesOrHistory() throws {
        let base = try iwad("doom2.wad")
        let a = try pwad("a.wad")
        let game = try service.createGame(name: "Sunlust", baseID: base.id, fileIDs: [a.id], complevel: "boom")
        try service.setSchemeOverride(TouchControlScheme.classic.rawValue, for: game)
        try service.markPlayed(game, at: Date(timeIntervalSince1970: 10))
        try service.hide(game)
        _ = try writeSave(forKey: game.id)

        let copy = try service.duplicate(game)

        XCTAssertNotEqual(copy.id, game.id)
        XCTAssertEqual(copy.name, "Sunlust copy")
        XCTAssertEqual(copy.baseID, base.id)
        XCTAssertEqual(copy.fileIDs, [a.id])
        XCTAssertEqual(copy.complevel, "boom")
        XCTAssertEqual(copy.schemeOverrideRaw, TouchControlScheme.classic.rawValue)
        XCTAssertFalse(copy.isBaseGame)
        XCTAssertFalse(copy.isHidden, "a copy is a fresh tile even if the original is hidden")
        XCTAssertNil(copy.lastPlayed)
        XCTAssertTrue(service.saveSlots(forKey: copy.id).isEmpty, "saves stay with the original")
        XCTAssertEqual(service.saveSlots(forKey: game.id).count, 1)
    }

    func testDuplicateOfABaseGameIsAnOrdinaryGame() throws {
        let base = try iwad("doom2.wad")
        let game = try XCTUnwrap(try service.game(id: base.id))
        let copy = try service.duplicate(game)
        XCTAssertFalse(copy.isBaseGame)
        XCTAssertEqual(copy.baseID, base.id)
        XCTAssertNotEqual(copy.id, base.id, "the copy must not steal the base game's saves key")
    }

    func testDuplicateApplyingAnEditLeavesTheOriginalUntouched() throws {
        let base = try iwad("doom2.wad")
        let a = try pwad("a.wad"), b = try pwad("b.wad")
        let game = try service.createGame(name: "Sunlust", baseID: base.id, fileIDs: [a.id])

        let copy = try service.duplicate(game, applying: .files([a.id, b.id]))

        XCTAssertEqual(copy.fileIDs, [a.id, b.id])
        XCTAssertEqual(try service.game(id: game.id)?.fileIDs, [a.id], "Duplicate Instead never edits the original")
    }

    // MARK: Delete offer (spec §4.4)

    func testDeletableMapSetsAreTheGamesUnsharedNonBundledMapSets() throws {
        let base = try iwad("doom2.wad")
        // Constructed directly rather than through `pwad()`/`registerImported`,
        // so these map sets arrive with no game of their own already pairing
        // them (spec §3.5) — this test is about sharing between the two games
        // created below, not about import-time pairing.
        func mapSet(_ name: String) -> WADFile {
            let wad = WADFile(filename: name, displayName: (name as NSString).deletingPathExtension,
                              kindRaw: WADKind.pwad.rawValue, sha1: name,
                              gameFamilyRaw: GameFamily.doom2.rawValue, hasMaps: true)
            context.insert(wad)
            return wad
        }
        let shared = mapSet("shared.wad")
        let mine = mapSet("mine.wad")
        let addOn = try pwad("smooth.wad", hasMaps: false)
        let game = try service.createGame(name: "A", baseID: base.id, fileIDs: [shared.id, mine.id, addOn.id])
        _ = try service.createGame(name: "B", baseID: base.id, fileIDs: [shared.id])

        XCTAssertEqual(try service.deletableMapSets(of: game).map(\.id), [mine.id],
                       "shared map sets and add-ons are never offered")
    }

    // MARK: Files screen groups (spec §3.4)

    func testFileGroupsAreByRoleBundledFirstThenFilename() throws {
        try service.seedBundledContentIfNeeded()
        _ = try iwad("DOOM2.WAD")
        _ = try pwad("sunlust.wad")
        _ = try pwad("smooth.wad", hasMaps: false)
        _ = try service.registerImported(filename: "fix.deh", sha1: "deh", kind: WADKind.deh.rawValue,
                                         family: GameFamily.unknown.rawValue)

        let groups = try service.fileGroups()

        XCTAssertEqual(groups.map(\.title), ["Base games", "Map sets", "Add-ons"])
        XCTAssertEqual(groups[0].wads.map(\.filename), ["freedoom1.wad", "freedoom2.wad", "DOOM2.WAD"])
        XCTAssertEqual(groups[1].wads.map(\.filename), ["sunlust.wad"])
        XCTAssertEqual(groups[2].wads.map(\.filename), ["fix.deh", "smooth.wad"], "patches and map-less PWADs share one group")
    }

    func testFileGroupsOmitEmptyRoles() throws {
        _ = try pwad("sunlust.wad")
        XCTAssertEqual(try service.fileGroups().map(\.title), ["Map sets"])
    }

    // MARK: Import pairing (spec §3.5, §4.1)

    func testImportingAMapSetCreatesAGamePairedToItsFamilysBase() throws {
        try service.seedBundledContentIfNeeded()               // freedoom1 (doom1), freedoom2 (doom2)
        let map = try service.registerImported(filename: "sunlust.wad", sha1: "s",
                                               kind: WADKind.pwad.rawValue, family: GameFamily.doom2.rawValue,
                                               hasMaps: true)
        let game = try XCTUnwrap(try service.gamesUsing(fileID: map.id).first)
        XCTAssertEqual(game.name, "sunlust")
        XCTAssertEqual(game.fileIDs, [map.id])
        XCTAssertFalse(game.isBaseGame)
        let freedoom2 = try XCTUnwrap(try service.allWADs().first { $0.filename == "freedoom2.wad" })
        XCTAssertEqual(game.baseID, freedoom2.id, "doom2-family map set pairs with the doom2-family base")
        XCTAssertTrue(try service.shelfGames().contains { $0.id == game.id }, "it is a tile")
    }

    func testImportingAMapSetPrefersAnImportedBaseAndIsNeverRePaired() throws {
        try service.seedBundledContentIfNeeded()
        let map = try service.registerImported(filename: "sunlust.wad", sha1: "s",
                                               kind: WADKind.pwad.rawValue, family: GameFamily.doom2.rawValue,
                                               hasMaps: true)
        let pairedToFreedoom = try XCTUnwrap(try service.gamesUsing(fileID: map.id).first).baseID
        // Now the real thing arrives. The existing game stays where it is (spec §4.1)…
        let doom2 = try service.registerImported(filename: "doom2.wad", sha1: "d",
                                                 kind: WADKind.iwad.rawValue, family: GameFamily.doom2.rawValue, hasMaps: true)
        XCTAssertEqual(try service.gamesUsing(fileID: map.id).first?.baseID, pairedToFreedoom, "no silent re-pairing")
        // …but a map set imported from now on prefers it.
        let later = try service.registerImported(filename: "valiant.wad", sha1: "v",
                                                 kind: WADKind.pwad.rawValue, family: GameFamily.doom2.rawValue, hasMaps: true)
        XCTAssertEqual(try service.gamesUsing(fileID: later.id).first?.baseID, doom2.id)
    }

    func testImportingAMapSetOfUnknownFamilyCreatesAnUnpairedGame() throws {
        try service.seedBundledContentIfNeeded()
        let map = try service.registerImported(filename: "weird.wad", sha1: "w",
                                               kind: WADKind.pwad.rawValue, family: GameFamily.unknown.rawValue,
                                               hasMaps: true)
        let game = try XCTUnwrap(try service.gamesUsing(fileID: map.id).first)
        XCTAssertNil(game.baseID)
        XCTAssertTrue(try service.shelfGames().contains { $0.id == game.id }, "unpaired games are still tiles (badge + page)")
    }

    func testImportingAnAddOnOrPatchCreatesNoGame() throws {
        try service.seedBundledContentIfNeeded()
        _ = try service.registerImported(filename: "smooth.wad", sha1: "a", kind: WADKind.pwad.rawValue,
                                         family: GameFamily.doom2.rawValue, hasMaps: false)
        _ = try service.registerImported(filename: "fix.deh", sha1: "p", kind: WADKind.deh.rawValue,
                                         family: GameFamily.unknown.rawValue)
        XCTAssertEqual(try service.games().count, 2, "only the two bundled base games")
    }

    /// `adoptMapSet` is the one construction `registerImported` and
    /// `adoptOrphanMapSets` now share — exercise it directly.
    func testAdoptMapSetPairsAndReturnsItsGame() throws {
        try service.seedBundledContentIfNeeded()
        let wad = WADFile(filename: "old.wad", displayName: "old", kindRaw: WADKind.pwad.rawValue,
                          sha1: "o", gameFamilyRaw: GameFamily.doom2.rawValue, hasMaps: true)
        context.insert(wad)
        try context.save()

        let game = try service.adoptMapSet(wad)

        XCTAssertEqual(game.fileIDs, [wad.id])
        let freedoom2 = try XCTUnwrap(try service.allWADs().first { $0.filename == "freedoom2.wad" })
        XCTAssertEqual(game.baseID, freedoom2.id)
        XCTAssertEqual(try service.gamesUsing(fileID: wad.id).first?.id, game.id)
    }

    // MARK: Orphan map-set sweep (spec §5 amendment)

    func testAdoptOrphanMapSetsGivesPreExistingMapSetsAGameOnce() throws {
        try service.seedBundledContentIfNeeded()
        // A map set that arrived before pairing existed: a row with maps and no game.
        let orphan = WADFile(filename: "old.wad", displayName: "old", kindRaw: WADKind.pwad.rawValue,
                             sha1: "o", gameFamilyRaw: GameFamily.doom1.rawValue, hasMaps: true)
        context.insert(orphan)
        // A map set already inside a game must not get a second tile.
        let owned = WADFile(filename: "owned.wad", displayName: "owned", kindRaw: WADKind.pwad.rawValue,
                            sha1: "w", gameFamilyRaw: GameFamily.doom1.rawValue, hasMaps: true)
        context.insert(owned)
        let freedoom1 = try XCTUnwrap(try service.allWADs().first { $0.filename == "freedoom1.wad" })
        _ = try service.createGame(name: "Mine", baseID: freedoom1.id, fileIDs: [owned.id])
        try context.save()
        let defaults = UserDefaults(suiteName: "adopt-\(UUID().uuidString)")!

        try service.adoptOrphanMapSets(defaults: defaults)

        let adopted = try XCTUnwrap(try service.gamesUsing(fileID: orphan.id).first)
        XCTAssertEqual(adopted.name, "old")
        XCTAssertEqual(adopted.baseID, freedoom1.id)
        XCTAssertEqual(try service.gamesUsing(fileID: owned.id).count, 1, "an owned map set is left alone")
        XCTAssertTrue(defaults.bool(forKey: LibraryService.didAdoptOrphanMapSetsKey))

        // Second run is a no-op even if the player deletes the adopted game.
        try service.deleteGame(adopted)
        try service.adoptOrphanMapSets(defaults: defaults)
        XCTAssertTrue(try service.gamesUsing(fileID: orphan.id).isEmpty, "the sweep runs once; a deleted game stays deleted")
    }
}
