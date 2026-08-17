import SwiftData
import XCTest
@testable import Waddle

@MainActor
final class PlayableItemTests: XCTestCase {
    var service: LibraryService!
    var tmp: URL!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, configurations: config)
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

    func testRecentlyPlayedMergesAndSortsAcrossKinds() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        let preset = try service.createLoadout(name: "P", iwadID: iwad.id, pwadIDs: [], dehIDs: [])
        // base game played most recently; preset earlier; a second base game never played.
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        preset.lastPlayed = older
        try service.saveChanges()
        try service.markPlayed(iwad, at: newer)
        let recent = try service.recentlyPlayed(limit: 10)
        XCTAssertEqual(recent.map(\.id), ["wad-\(iwad.id)", "loadout-\(preset.id)"])
    }

    func testRecentlyPlayedExcludesNeverPlayedAndRespectsLimit() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        _ = try service.createLoadout(name: "NeverPlayed", iwadID: iwad.id, pwadIDs: [], dehIDs: [])
        try service.markPlayed(iwad, at: Date(timeIntervalSince1970: 50))
        let recent = try service.recentlyPlayed(limit: 1)
        XCTAssertEqual(recent.map(\.id), ["wad-\(iwad.id)"])
    }
}
