import SwiftData
import XCTest
@testable import Waddle

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

    func testSeedStoresRealContentHashForBundledIWADs() throws {
        try service.seedBundledContentIfNeeded()
        let bundled = try service.allWADs().filter(\.isBundled)
        XCTAssertEqual(bundled.count, 2)
        for wad in bundled {
            XCTAssertEqual(wad.sha1, try WADStore.sha1(ofFileAt: service.fileURL(for: wad)),
                           "\(wad.filename) must carry its real content hash so " +
                           "imports of identical content dedupe against it")
        }
    }

    /// A pre-`Game` preset row, inserted directly now that the legacy
    /// loadout-creation API is gone; the reconcile these tests cover reads
    /// the tombstone table directly.
    @discardableResult
    private func insertLegacyLoadout(name: String, iwadID: UUID,
                                     pwadIDs: [UUID] = [], dehIDs: [UUID] = []) throws -> Loadout {
        let loadout = Loadout(name: name, iwadID: iwadID, pwadIDs: pwadIDs, dehIDs: dehIDs)
        context.insert(loadout)
        try context.save()
        return loadout
    }

    private func legacyLoadouts() throws -> [Loadout] {
        try context.fetch(FetchDescriptor<Loadout>())
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
        let phantom = try insertLegacyLoadout(name: "Freedoom Phase 1", iwadID: base.id)
        let oldDir = LibraryService.savesDirectory(forGameID: phantom.id)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try Data("save".utf8).write(to: oldDir.appendingPathComponent("slot.dsg"))

        // Fresh, empty UserDefaults so the one-time guard's flag starts unset.
        let d = UserDefaults(suiteName: "reconcile-\(UUID().uuidString)")!
        try service.reconcileBundledBaseGameLoadouts(defaults: d)

        XCTAssertTrue(try legacyLoadouts().isEmpty, "phantom loadout not removed")
        let newDir = LibraryService.savesDirectory(forGameID: base.id)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: newDir.appendingPathComponent("slot.dsg").path),
            "saves not migrated to base-game key")
        try? FileManager.default.removeItem(at: newDir)

        // A second call with the same defaults is a no-op: the flag is set,
        // and re-creating the phantom shape (name only, no isBundled tie yet)
        // would otherwise be silently swept away by a later launch.
        let again = try insertLegacyLoadout(name: "Freedoom Phase 1", iwadID: base.id)
        try service.reconcileBundledBaseGameLoadouts(defaults: d)
        XCTAssertEqual(Set(try legacyLoadouts().map(\.name)), Set(["Freedoom Phase 1"]),
                       "second call should be a no-op once the flag is set")
        context.delete(again)
        try context.save()
    }

    func testReconcileLeavesUserPresetsUntouched() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        _ = try insertLegacyLoadout(name: "My Stack", iwadID: iwad.id)
        let d = UserDefaults(suiteName: "reconcile-\(UUID().uuidString)")!
        try service.reconcileBundledBaseGameLoadouts(defaults: d)
        XCTAssertEqual(Set(try legacyLoadouts().map(\.name)), Set(["My Stack"]))
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
        _ = try insertLegacyLoadout(name: "Freedoom Phase 1", iwadID: base.id)
        _ = try insertLegacyLoadout(name: "Freedoom Phase 1", iwadID: base.id)

        let d = UserDefaults(suiteName: "reconcile-\(UUID().uuidString)")!
        try service.reconcileBundledBaseGameLoadouts(defaults: d)

        XCTAssertEqual(try legacyLoadouts().filter { $0.name == "Freedoom Phase 1" }.count, 2,
                       "ambiguous duplicate titles must be preserved, not deleted")
    }

    func testReconcileMergesSavesWithoutClobberingExistingBaseGameSaves() throws {
        let base = try service.registerImported(
            filename: "freedoom1.wad", sha1: "bundled:freedoom1.wad",
            kind: WADKind.iwad.rawValue, family: GameFamily.doom1.rawValue)
        base.isBundled = true
        try service.saveChanges()
        let phantom = try insertLegacyLoadout(name: "Freedoom Phase 1", iwadID: base.id)
        // Legacy saves under the loadout key: a.dsg (collides) + b.dsg (new).
        let oldDir = LibraryService.savesDirectory(forGameID: phantom.id)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try Data("old-a".utf8).write(to: oldDir.appendingPathComponent("a.dsg"))
        try Data("old-b".utf8).write(to: oldDir.appendingPathComponent("b.dsg"))
        // Base game already played: its saves dir exists with a colliding a.dsg.
        let newDir = LibraryService.savesDirectory(forGameID: base.id)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try Data("base-a".utf8).write(to: newDir.appendingPathComponent("a.dsg"))

        let d = UserDefaults(suiteName: "reconcile-\(UUID().uuidString)")!
        try service.reconcileBundledBaseGameLoadouts(defaults: d)

        XCTAssertTrue(try legacyLoadouts().isEmpty, "lone phantom should be removed after successful migration")
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

    func testDeleteWADBlockedByALegacyLoadoutIsNotAThing() throws {
        // Loadout rows are a schema tombstone: nothing reads them for
        // in-use checks any more. `GameServiceTests.testDeleteWADIsBlockedByAnyOtherGameUsingIt`
        // is where the in-use rule lives now.
        let pwad = try service.registerImported(filename: "sunlust.wad", sha1: "p1",
                                                kind: WADKind.pwad.rawValue, family: "doom2")
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i1",
                                                 kind: WADKind.iwad.rawValue, family: "doom2")
        try insertLegacyLoadout(name: "Legacy", iwadID: iwad.id, pwadIDs: [pwad.id])

        try service.deleteWAD(pwad)

        XCTAssertNil(try service.wad(id: pwad.id))
        XCTAssertEqual(try legacyLoadouts().count, 1, "the tombstone row is untouched and never a blocker")
    }

    func testSaveSlotsListsFilesNewestFirst() throws {
        let key = UUID()
        let dir = LibraryService.savesDirectory(forGameID: key)
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

    // MARK: - File inventory (Plan D)

    /// Writes real bytes into the service's store directory so status/size
    /// checks see an actual on-disk file, then registers a matching row.
    @discardableResult
    private func registerWithBacking(_ filename: String, kind: WADKind,
                                     bytes: Int = 16) throws -> WADFile {
        let url = tmp.appendingPathComponent(filename)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return try service.registerImported(filename: filename, sha1: "sha-\(filename)",
                                            kind: kind.rawValue,
                                            family: GameFamily.unknown.rawValue)
    }

    func testLibraryGroupsOrderedByKindWithTitles() throws {
        try service.seedBundledContentIfNeeded()   // 2 bundled IWADs
        try registerWithBacking("sunlust.wad", kind: .pwad)
        try registerWithBacking("tweak.deh", kind: .deh)
        let groups = try service.libraryGroups()
        XCTAssertEqual(groups.map(\.title), ["Base Games", "Mods", "Patches"])
        XCTAssertEqual(groups[0].wads.map(\.filename), ["freedoom1.wad", "freedoom2.wad"])
        XCTAssertEqual(groups[1].wads.map(\.filename), ["sunlust.wad"])
        XCTAssertEqual(groups[2].wads.map(\.filename), ["tweak.deh"])
    }

    func testLibraryGroupsOmitsEmptyKinds() throws {
        try registerWithBacking("sunlust.wad", kind: .pwad)
        let groups = try service.libraryGroups()
        XCTAssertEqual(groups.map(\.title), ["Mods"])
    }

    func testLibraryGroupsSortsBundledFirstThenFilename() throws {
        // A user-imported IWAD named to sort before "freedoom1.wad"
        // alphabetically must still list after the bundled entries.
        try registerWithBacking("DOOM2.WAD", kind: .iwad)
        try service.seedBundledContentIfNeeded()
        let groups = try service.libraryGroups()
        XCTAssertEqual(groups[0].wads.map(\.filename),
                       ["freedoom1.wad", "freedoom2.wad", "DOOM2.WAD"])
    }

    func testFileStatusBundledImportedAndMissing() throws {
        try service.seedBundledContentIfNeeded()
        let bundled = try XCTUnwrap(service.baseGames().first)
        XCTAssertEqual(service.fileStatus(for: bundled), .bundled)

        let imported = try registerWithBacking("sunlust.wad", kind: .pwad)
        XCTAssertEqual(service.fileStatus(for: imported), .imported)

        // Row exists but the backing file vanished (deleted out-of-band in Files).
        let ghost = try service.registerImported(filename: "gone.wad", sha1: "sha-gone",
                                                 kind: WADKind.pwad.rawValue,
                                                 family: GameFamily.unknown.rawValue)
        XCTAssertEqual(service.fileStatus(for: ghost), .missing)
    }

    func testFileSizeReportsOnDiskBytesAndNilWhenMissing() throws {
        let imported = try registerWithBacking("sunlust.wad", kind: .pwad, bytes: 1234)
        XCTAssertEqual(service.fileSize(for: imported), 1234)

        let ghost = try service.registerImported(filename: "gone.wad", sha1: "sha-gone2",
                                                 kind: WADKind.pwad.rawValue,
                                                 family: GameFamily.unknown.rawValue)
        XCTAssertNil(service.fileSize(for: ghost))
    }

    // MARK: Hide / restore (spec §4: reversible "Remove from Shelf")

    func testHiddenGamesFileStillListedInLibraryInventory() throws {
        let iwad = try registerWithBacking("doom2.wad", kind: .iwad)
        try service.hide(try XCTUnwrap(try service.game(id: iwad.id)))
        // Manage is the file inventory, not the shelf: a hidden game's file is
        // still on disk and must stay visible (and manageable) there.
        XCTAssertTrue(try service.allWADs().contains { $0.id == iwad.id })
        XCTAssertTrue(try service.libraryGroups().flatMap(\.wads).contains { $0.id == iwad.id })
    }

    // MARK: seedContinueSaveForCapture (test-only seam)

    /// The property the App Store shot actually depends on is not "a file
    /// exists" but "`EngineSaveSlot` resolves a slot from it", since that is
    /// what `ShelfView.hasResumableSave` calls to decide whether to draw the
    /// Continue hero. Assert the resolution, not just the filename.
    func testSeedContinueSaveMakesTheNewestPlayedItemResumable() throws {
        try service.seedBundledContentIfNeeded()
        let freedoom1 = try XCTUnwrap(try service.allWADs().first { $0.filename == "freedoom1.wad" })
        try service.markPlayed(try XCTUnwrap(try service.game(id: freedoom1.id)))
        let dir = LibraryService.savesDirectory(forGameID: freedoom1.id)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(EngineSaveSlot.newestLoadGameArgument(in: service.saveSlots(forKey: freedoom1.id)),
                     "precondition: a warped capture session leaves no save behind")

        try service.seedContinueSaveForCapture()

        XCTAssertEqual(
            EngineSaveSlot.newestLoadGameArgument(in: service.saveSlots(forKey: freedoom1.id)),
            EngineSaveSlot.autoSaveArgument,
            "the seeded save must resolve as the autosave, or the shelf draws no Continue hero")
    }

    /// A real save must always win. If the capture device has genuine progress,
    /// seeding over it would replace a loadable save with a marker that only
    /// looks like one.
    func testSeedContinueSaveLeavesAnExistingSaveAlone() throws {
        try service.seedBundledContentIfNeeded()
        let freedoom1 = try XCTUnwrap(try service.allWADs().first { $0.filename == "freedoom1.wad" })
        try service.markPlayed(try XCTUnwrap(try service.game(id: freedoom1.id)))
        let dir = LibraryService.savesDirectory(forGameID: freedoom1.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("woofsav03.dsg")
        try Data("a real save".utf8).write(to: real)

        try service.seedContinueSaveForCapture()

        XCTAssertEqual(try Data(contentsOf: real), Data("a real save".utf8),
                       "an existing save was modified")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(EngineSaveSlot.autoSaveFilename).path),
            "seeding must no-op when the item already has a save")
    }

    /// Nothing played means nothing to continue — seeding must not invent a
    /// hero for an item the player has never opened.
    func testSeedContinueSaveDoesNothingWhenNothingWasPlayed() throws {
        try service.seedBundledContentIfNeeded()
        let freedoom1 = try XCTUnwrap(try service.allWADs().first { $0.filename == "freedoom1.wad" })
        let dir = LibraryService.savesDirectory(forGameID: freedoom1.id)
        defer { try? FileManager.default.removeItem(at: dir) }

        try service.seedContinueSaveForCapture()

        XCTAssertTrue(service.saveSlots(forKey: freedoom1.id).isEmpty,
                      "seeded a save for an item that was never played")
    }
}
