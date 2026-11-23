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
        let container = try ModelContainer(for: WADFile.self, Game.self, configurations: config)
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

    func testRegisterAndFindBySHA1() throws {
        let wad = try service.registerImported(filename: "sunlust.wad", sha1: "abc123",
                                               kind: WADKind.pwad.rawValue, family: "doom2")
        XCTAssertEqual(try service.findWAD(sha1: "abc123")?.id, wad.id)
        XCTAssertNil(try service.findWAD(sha1: "nope"))
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
        XCTAssertTrue(try service.fileGroups().flatMap(\.wads).contains { $0.id == iwad.id })
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

    // MARK: A build that no longer bundles Freedoom (issue #503)

    /// Points the service's bundle location at an empty directory under `tmp`,
    /// which is how a build without `GameData/freedoom*.wad` looks to it.
    private func shipWithoutFreedoom() throws {
        let empty = tmp.appendingPathComponent("EmptyGameData-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        service.bundledContentDirectory = empty
    }

    private func writeSave(forGameID id: UUID) throws -> URL {
        let dir = LibraryService.savesDirectory(forGameID: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try Data("save".utf8).write(to: dir.appendingPathComponent("woofsav0.dsg"))
        return dir
    }

    func testSeederOnAFreshStoreWithoutBundledFilesRegistersNothing() throws {
        try shipWithoutFreedoom()

        XCTAssertNoThrow(try service.seedBundledContentIfNeeded(),
                         "WaddleApp.init turns a throw here into fatalError on first launch")

        XCTAssertTrue(try service.allWADs().isEmpty)
        XCTAssertTrue(try service.games().isEmpty)
    }

    func testSeederReleasesABundledRowWhoseFileIsGoneKeepingItsGameAndSaves() throws {
        try service.seedBundledContentIfNeeded()
        let before = try service.allWADs()
        let phase1 = try XCTUnwrap(before.first { $0.filename == "freedoom1.wad" })
        let id = phase1.id, sha1 = phase1.sha1
        let game = try XCTUnwrap(try service.game(id: id))
        try service.hide(game)
        let saves = try writeSave(forGameID: id)

        try shipWithoutFreedoom()
        try service.seedBundledContentIfNeeded()

        XCTAssertEqual(Set(try service.allWADs().map(\.id)), Set(before.map(\.id)),
                       "no row may be dropped or re-created under a fresh id")
        let released = try XCTUnwrap(try service.wad(id: id))
        XCTAssertEqual(service.fileStatus(for: released), .missing)
        XCTAssertFalse(released.isBundled)
        XCTAssertEqual(released.displayName, "Freedoom Phase 1")
        XCTAssertEqual(released.sha1, sha1, "the hash is what a re-import is matched on")
        XCTAssertEqual(released.kindRaw, WADKind.iwad.rawValue)
        let kept = try XCTUnwrap(try service.game(id: id), "its base game must survive")
        XCTAssertTrue(kept.isBaseGame)
        XCTAssertTrue(kept.isHidden, "the player's Remove from Shelf must survive")
        XCTAssertEqual(try service.games().count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saves.path))
        XCTAssertEqual(service.saveSlots(forKey: id).map(\.id), ["woofsav0.dsg"])
    }

    func testSeederWithoutBundledFilesIsIdempotent() throws {
        try service.seedBundledContentIfNeeded()
        try shipWithoutFreedoom()

        func snapshot() throws -> [String] {
            try service.allWADs().map {
                "\($0.id) \($0.filename) \($0.isBundled) \($0.displayName) \(service.fileStatus(for: $0))"
            }.sorted()
            + service.games().map { "\($0.id) \($0.name) \($0.isHidden)" }.sorted()
        }
        try service.seedBundledContentIfNeeded()
        let once = try snapshot()
        try service.seedBundledContentIfNeeded()

        XCTAssertEqual(try snapshot(), once)
    }

    /// Content matching the bundled hash can never have been imported (it
    /// deduped against the bundled row), so a store file under the bundled
    /// name is somebody else's. The released row must not claim it.
    func testReleasedRowDoesNotClaimADifferentStoredFileWithItsName() throws {
        try service.seedBundledContentIfNeeded()
        let phase1 = try XCTUnwrap(try service.allWADs().first { $0.filename == "freedoom1.wad" })
        try Data(repeating: 0xCD, count: 64).write(to: tmp.appendingPathComponent("freedoom1.wad"))

        try shipWithoutFreedoom()
        try service.seedBundledContentIfNeeded()

        let released = try XCTUnwrap(try service.wad(id: phase1.id))
        XCTAssertNotEqual(released.filename, "freedoom1.wad")
        XCTAssertEqual(service.fileStatus(for: released), .missing)
    }

    /// Rows from before store names were reserved can name one store file
    /// twice. Deleting either must leave the file for the other.
    func testDeletingARowLeavesAFileAnotherRowStillNames() throws {
        let kept = try registerWithBacking("shared.wad", kind: .pwad)
        let deleted = try service.registerImported(filename: "shared.wad", sha1: "sha-other",
                                                   kind: WADKind.pwad.rawValue,
                                                   family: GameFamily.unknown.rawValue)

        try service.deleteWAD(deleted)

        XCTAssertEqual(service.fileStatus(for: kept), .imported)
    }

    // MARK: Legacy placeholder hashes (issue #503 review)

    func testSeederRehashesALegacyPlaceholderWhileTheFileShips() throws {
        try service.seedBundledContentIfNeeded()
        let phase1 = try XCTUnwrap(try service.allWADs().first { $0.filename == "freedoom1.wad" })
        let real = phase1.sha1
        phase1.sha1 = "bundled:freedoom1.wad"   // seeded before a1dc675a
        try service.saveChanges()

        try service.seedBundledContentIfNeeded()

        XCTAssertEqual(phase1.sha1, real)
        XCTAssertTrue(phase1.isBundled)
    }

    /// `shippedFreedoomSHA1` is what builds before a1dc675a shipped, and so
    /// what a placeholder row's bytes were. It holds today because the app
    /// still bundles that release. If a Freedoom bump fails this, the table
    /// is still right — keep its 0.13.0 hashes and change this test instead.
    func testShippedFreedoomSHA1IsTheBundledRelease() throws {
        try service.seedBundledContentIfNeeded()
        for wad in try service.allWADs() where wad.isBundled {
            XCTAssertEqual(LibraryService.shippedFreedoomSHA1[wad.filename], wad.sha1, wad.filename)
        }
    }

    func testReleasingALegacyPlaceholderRowGivesItTheShippedHash() throws {
        try service.seedBundledContentIfNeeded()
        for wad in try service.allWADs() { wad.sha1 = "bundled:\(wad.filename)" }
        try service.saveChanges()

        try shipWithoutFreedoom()
        try service.seedBundledContentIfNeeded()

        for wad in try service.allWADs() {
            XCTAssertEqual(wad.sha1, LibraryService.shippedFreedoomSHA1[wad.filename], wad.filename)
            XCTAssertEqual(service.fileStatus(for: wad), .missing)
        }
    }

    /// The wiring for `Pairing`'s presence rule: a released Freedoom, played
    /// and imported-looking, must not take a new map set from a present IWAD.
    func testPairBasePrefersAPresentIWADOverAReleasedFreedoom() throws {
        try service.seedBundledContentIfNeeded()
        let phase1 = try XCTUnwrap(try service.allWADs().first { $0.filename == "freedoom1.wad" })
        try service.markPlayed(try XCTUnwrap(try service.game(id: phase1.id)))
        let url = tmp.appendingPathComponent("doom.wad")
        try Data(repeating: 0xAB, count: 16).write(to: url)
        let doom = try service.registerImported(filename: "doom.wad", sha1: "sha-doom",
                                                kind: WADKind.iwad.rawValue,
                                                family: GameFamily.doom1.rawValue)
        try shipWithoutFreedoom()
        try service.seedBundledContentIfNeeded()

        XCTAssertEqual(try service.pairBase(forFamily: .doom1)?.id, doom.id)
    }
}
