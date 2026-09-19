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
}
