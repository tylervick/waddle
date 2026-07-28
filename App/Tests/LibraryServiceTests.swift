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

    func testSeedCreatesFreedoomWADsButNoLoadouts() throws {
        try service.seedBundledContentIfNeeded()
        try service.seedBundledContentIfNeeded()   // idempotent
        XCTAssertEqual(try service.allWADs().filter(\.isBundled).map(\.filename).sorted(),
                       ["freedoom1.wad", "freedoom2.wad"])
        XCTAssertTrue(try service.allLoadouts().isEmpty)
    }

    func testReconcileRemovesPhantomBaseGameLoadoutAndMigratesSaves() throws {
        // Arrange an old-install shape: a bundled Freedoom IWAD + a phantom
        // "Freedoom Phase 1" loadout (no PWAD/DEH) that accumulated a save.
        // isBundled must be true for reconciliation to treat it as a phantom;
        // registerImported creates a non-bundled row, so set the flag after.
        let base = try service.registerImported(
            filename: "freedoom1.wad", sha1: "bundled:freedoom1.wad",
            kind: WADKind.iwad.rawValue, family: GameFamily.doom1.rawValue)
        base.isBundled = true
        try service.saveChanges()
        let phantom = try service.createLoadout(name: "Freedoom Phase 1",
                                                iwadID: base.id, pwadIDs: [], dehIDs: [])
        let oldDir = LibraryService.savesDirectory(forLoadoutID: phantom.id)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try Data("save".utf8).write(to: oldDir.appendingPathComponent("slot.dsg"))

        // Fresh, empty UserDefaults so the one-time guard's flag starts unset.
        let d = UserDefaults(suiteName: "reconcile-\(UUID().uuidString)")!
        try service.reconcileBundledBaseGameLoadouts(defaults: d)

        XCTAssertTrue(try service.allLoadouts().isEmpty, "phantom loadout not removed")
        let newDir = LibraryService.savesDirectory(forLoadoutID: base.id)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: newDir.appendingPathComponent("slot.dsg").path),
            "saves not migrated to base-game key")
        try? FileManager.default.removeItem(at: newDir)

        // A second call with the same defaults is a no-op: the flag is set,
        // and re-creating the phantom shape (name only, no isBundled tie yet)
        // would otherwise be silently swept away by a later launch.
        let again = try service.createLoadout(name: "Freedoom Phase 1",
                                              iwadID: base.id, pwadIDs: [], dehIDs: [])
        try service.reconcileBundledBaseGameLoadouts(defaults: d)
        XCTAssertEqual(try service.allLoadouts().map(\.name), ["Freedoom Phase 1"],
                       "second call should be a no-op once the flag is set")
        try service.deleteLoadout(again, deleteSaves: false)
    }

    func testReconcileLeavesUserPresetsUntouched() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        _ = try service.createLoadout(name: "My Stack", iwadID: iwad.id, pwadIDs: [], dehIDs: [])
        let d = UserDefaults(suiteName: "reconcile-\(UUID().uuidString)")!
        try service.reconcileBundledBaseGameLoadouts(defaults: d)
        XCTAssertEqual(try service.allLoadouts().map(\.name), ["My Stack"])
    }

    func testReconcilePreservesAmbiguousDuplicateSeededTitles() throws {
        // Two modless loadouts share the seeded phantom shape on the bundled
        // IWAD. A legacy install made exactly one phantom per phase, so this is
        // ambiguous (the user likely made one) — neither may be deleted.
        let base = try service.registerImported(
            filename: "freedoom1.wad", sha1: "bundled:freedoom1.wad",
            kind: WADKind.iwad.rawValue, family: GameFamily.doom1.rawValue)
        base.isBundled = true
        try service.saveChanges()
        _ = try service.createLoadout(name: "Freedoom Phase 1", iwadID: base.id, pwadIDs: [], dehIDs: [])
        _ = try service.createLoadout(name: "Freedoom Phase 1", iwadID: base.id, pwadIDs: [], dehIDs: [])

        let d = UserDefaults(suiteName: "reconcile-\(UUID().uuidString)")!
        try service.reconcileBundledBaseGameLoadouts(defaults: d)

        XCTAssertEqual(try service.allLoadouts().filter { $0.name == "Freedoom Phase 1" }.count, 2,
                       "ambiguous duplicate titles must be preserved, not deleted")
    }

    func testReconcileMergesSavesWithoutClobberingExistingBaseGameSaves() throws {
        let base = try service.registerImported(
            filename: "freedoom1.wad", sha1: "bundled:freedoom1.wad",
            kind: WADKind.iwad.rawValue, family: GameFamily.doom1.rawValue)
        base.isBundled = true
        try service.saveChanges()
        let phantom = try service.createLoadout(name: "Freedoom Phase 1",
                                                iwadID: base.id, pwadIDs: [], dehIDs: [])
        // Legacy saves under the loadout key: a.dsg (collides) + b.dsg (new).
        let oldDir = LibraryService.savesDirectory(forLoadoutID: phantom.id)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try Data("old-a".utf8).write(to: oldDir.appendingPathComponent("a.dsg"))
        try Data("old-b".utf8).write(to: oldDir.appendingPathComponent("b.dsg"))
        // Base game already played: its saves dir exists with a colliding a.dsg.
        let newDir = LibraryService.savesDirectory(forLoadoutID: base.id)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try Data("base-a".utf8).write(to: newDir.appendingPathComponent("a.dsg"))

        let d = UserDefaults(suiteName: "reconcile-\(UUID().uuidString)")!
        try service.reconcileBundledBaseGameLoadouts(defaults: d)

        XCTAssertTrue(try service.allLoadouts().isEmpty, "lone phantom should be removed after successful migration")
        XCTAssertEqual(try String(contentsOf: newDir.appendingPathComponent("a.dsg"), encoding: .utf8),
                       "base-a", "existing base-game save must not be clobbered")
        XCTAssertEqual(try String(contentsOf: newDir.appendingPathComponent("b.dsg"), encoding: .utf8),
                       "old-b", "non-colliding legacy save must migrate in")
        try? FileManager.default.removeItem(at: newDir)
        try? FileManager.default.removeItem(at: oldDir)
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

    func testMarkPlayedStampsLastPlayed() throws {
        let wad = try service.registerImported(filename: "doom2.wad", sha1: "i1",
                                               kind: WADKind.iwad.rawValue, family: "doom2")
        XCTAssertNil(wad.lastPlayed)
        let when = Date(timeIntervalSince1970: 1_000_000)
        try service.markPlayed(wad, at: when)
        XCTAssertEqual(try service.wad(id: wad.id)?.lastPlayed, when)
    }

    func testLoadoutSchemeOverridePersists() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i1",
                                                kind: WADKind.iwad.rawValue, family: "doom2")
        let loadout = try service.createLoadout(name: "L", iwadID: iwad.id, pwadIDs: [], dehIDs: [])
        loadout.schemeOverrideRaw = TouchControlScheme.modern.rawValue
        try service.saveChanges()
        XCTAssertEqual(try service.allLoadouts().first?.schemeOverrideRaw,
                       TouchControlScheme.modern.rawValue)
    }

    func testSetSchemeOverrideOnBaseGameAndPreset() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        let preset = try service.createLoadout(name: "P", iwadID: iwad.id, pwadIDs: [], dehIDs: [])
        try service.setSchemeOverride(TouchControlScheme.classic.rawValue, forBaseGame: iwad)
        try service.setSchemeOverride(TouchControlScheme.modern.rawValue, forPreset: preset)
        XCTAssertEqual(try service.wad(id: iwad.id)?.schemeOverrideRaw, TouchControlScheme.classic.rawValue)
        XCTAssertEqual(try service.allLoadouts().first?.schemeOverrideRaw, TouchControlScheme.modern.rawValue)
        try service.setSchemeOverride(nil, forBaseGame: iwad)
        XCTAssertNil(try service.wad(id: iwad.id)?.schemeOverrideRaw)
    }

    func testSaveSlotsListsFilesNewestFirst() throws {
        let key = UUID()
        let dir = LibraryService.savesDirectory(forLoadoutID: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.dsg"); let b = dir.appendingPathComponent("b.dsg")
        try Data().write(to: a); try Data().write(to: b)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: a.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: b.path)
        XCTAssertEqual(service.saveSlots(forKey: key).map(\.id), ["b.dsg", "a.dsg"])
        try? FileManager.default.removeItem(at: dir)
    }

    func testPresetNameSuggestion() {
        XCTAssertEqual(PresetName.suggested(base: "Doom II", pwads: []), "Doom II")
        XCTAssertEqual(PresetName.suggested(base: "Doom II", pwads: ["Sunlust"]), "Doom II + Sunlust")
        XCTAssertEqual(PresetName.suggested(base: "Doom II", pwads: ["A", "B"]), "Doom II + A + B")
    }
}
