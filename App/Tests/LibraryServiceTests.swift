import SwiftData
import XCTest
@testable import WADdle

@MainActor
final class LibraryServiceTests: XCTestCase {
    var service: LibraryService!
    var context: ModelContext!
    var tmp: URL!

    // Deviation from brief: the brief's setUpWithError()/tearDownWithError()
    // overrides are inherited nonisolated (unannotated ObjC-imported XCTestCase
    // requirements), so even in a @MainActor test class they'd run outside the
    // main actor. Swift 6's "sending" checker then balks at handing the
    // MainActor-isolated ModelContext into LibraryService's @MainActor init.
    // The async setUp()/tearDown() overrides are properly MainActor-isolated
    // (XCTest awaits them), so using those instead resolves the diagnostic
    // without any unsafe opt-outs. Behavior is identical: XCTest calls one
    // setUp/tearDown pair per test, synchronously in effect.
    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, configurations: config)
        context = ModelContext(container)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        service = LibraryService(context: context, store: WADStore(directory: tmp))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testSeedCreatesFreedoomEntriesAndLoadoutsOnce() throws {
        try service.seedBundledContentIfNeeded()
        try service.seedBundledContentIfNeeded()   // idempotent
        let wads = try service.allWADs()
        XCTAssertEqual(wads.filter(\.isBundled).map(\.filename).sorted(),
                       ["freedoom1.wad", "freedoom2.wad"])
        let loadouts = try service.allLoadouts()
        XCTAssertEqual(loadouts.map(\.name).sorted(),
                       ["Freedoom Phase 1", "Freedoom Phase 2"])
    }

    func testRegisterAndFindBySHA1() throws {
        let wad = try service.registerImported(filename: "sunlust.wad", sha1: "abc123",
                                               kind: WADKind.pwad.rawValue, family: "doom2")
        XCTAssertEqual(try service.findWAD(sha1: "abc123")?.id, wad.id)
        XCTAssertNil(try service.findWAD(sha1: "nope"))
    }

    func testDeleteWADReferencedByLoadoutThrowsUnlessForced() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i1",
                                                kind: WADKind.iwad.rawValue, family: "doom2")
        let pwad = try service.registerImported(filename: "sunlust.wad", sha1: "p1",
                                                kind: WADKind.pwad.rawValue, family: "doom2")
        let loadout = try service.createLoadout(name: "Sunlust", iwadID: iwad.id,
                                                pwadIDs: [pwad.id], dehIDs: [])
        XCTAssertThrowsError(try service.deleteWAD(pwad, force: false)) {
            XCTAssertEqual($0 as? LibraryError, .wadReferencedByLoadouts(["Sunlust"]))
        }
        try service.deleteWAD(pwad, force: true)
        XCTAssertNil(try service.wad(id: pwad.id))
        _ = loadout
    }

    func testDeleteLoadoutRemovesSavesWhenAsked() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i2",
                                                kind: WADKind.iwad.rawValue, family: "doom2")
        let loadout = try service.createLoadout(name: "X", iwadID: iwad.id, pwadIDs: [], dehIDs: [])
        let saves = LibraryService.savesDirectory(forLoadoutID: loadout.id)
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        try Data("save".utf8).write(to: saves.appendingPathComponent("savegame0.dsg"))
        try service.deleteLoadout(loadout, deleteSaves: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: saves.path))
        XCTAssertTrue(try service.allLoadouts().isEmpty)
    }

    func testLoadoutOrderingPreserved() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i3",
                                                kind: WADKind.iwad.rawValue, family: "doom2")
        let a = try service.registerImported(filename: "a.wad", sha1: "a", kind: WADKind.pwad.rawValue, family: "doom2")
        let b = try service.registerImported(filename: "b.wad", sha1: "b", kind: WADKind.pwad.rawValue, family: "doom2")
        let loadout = try service.createLoadout(name: "Ordered", iwadID: iwad.id,
                                                pwadIDs: [b.id, a.id], dehIDs: [])
        XCTAssertEqual(loadout.pwadIDs, [b.id, a.id])
    }

    func testAllLoadoutsSortsMostRecentFirst() throws {
        let iwad = try service.registerImported(filename: "d.wad", sha1: "s1",
                                                kind: "IWAD", family: "doom2")
        let old = try service.createLoadout(name: "Old", iwadID: iwad.id, pwadIDs: [], dehIDs: [])
        let recent = try service.createLoadout(name: "Recent", iwadID: iwad.id, pwadIDs: [], dehIDs: [])
        old.lastPlayed = Date(timeIntervalSinceNow: -3600)
        recent.lastPlayed = Date()
        XCTAssertEqual(try service.allLoadouts().map(\.name), ["Recent", "Old"])
    }
}
