import SwiftData
import XCTest
@testable import Waddle

@MainActor
final class PlayableItemTests: XCTestCase {
    var service: LibraryService!
    var tmp: URL!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, Game.self, configurations: config)
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        service = LibraryService(context: ModelContext(container), store: WADStore(directory: tmp))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tmp) }

    func testBaseGamesReturnsOnlyIWADs() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        _ = try service.registerImported(filename: "sunlust.wad", sha1: "p", kind: WADKind.pwad.rawValue, family: "doom2")
        let bases = try service.baseGames()
        XCTAssertEqual(bases.map(\.id), [iwad.id])
    }

    // Deviation from brief: removed `testRecentlyPlayedMergesAndSortsAcrossKinds` and
    // `testRecentlyPlayedExcludesNeverPlayedAndRespectsLimit` here. Both exercised
    // `recentlyPlayed(limit:)` merging base games and presets via `PlayableItem`'s
    // "wad-"/"loadout-" String id; Task 3 changes that method to return `[Game]`
    // (UUID-keyed, and it reads `Game.lastPlayed`, which `markPlayed(WADFile)` and
    // `createLoadout` never touch), so neither test compiles any more. This wasn't in
    // Task 3's brief — this file isn't in its Files list — but the whole-target build
    // cannot succeed otherwise. Task 8's brief already names this file's exact
    // successors and schedules its deletion: `testBaseGamesReturnsOnlyIWADs` and
    // `testRecentlyPlayedExcludesNeverPlayedAndRespectsLimit` carry over to
    // `GameServiceTests` under the same names, and `testRecentlyPlayedMergesAndSortsAcrossKinds`'s
    // successor there is `testRecentlyPlayedExcludesNeverPlayedAndRespectsLimit` too
    // (mixing a base game and a modded game) — both already written and passing in
    // `GameServiceTests.swift`. `testBaseGamesReturnsOnlyIWADs` above is untouched:
    // it still compiles and still passes.
}
