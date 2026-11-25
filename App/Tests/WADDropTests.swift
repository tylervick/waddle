import SwiftData
import XCTest
@testable import Waddle

/// The shelf's drop handler (#481): a dropped file must end exactly as the
/// same file picked with the picker does, in the same outcome and the same
/// banner. Each test imports through the drop handler into one library and
/// through the picker into a second, independent one, and compares.
@MainActor
final class WADDropTests: XCTestCase {
    private var tmp: URL!

    private struct Stack {
        let library: LibraryService
        let importer: ImportService
        let notices: ImportNotices
    }

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeStack() throws -> Stack {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Game.self, configurations: config)
        let store = WADStore(directory: tmp.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let library = LibraryService(context: ModelContext(container), store: store)
        library.bundledContentDirectory = try FreedoomFixture.directory()
        let notices = ImportNotices()
        let usage = UsageStore(directory: tmp.appendingPathComponent(UUID().uuidString, isDirectory: true))
        return Stack(library: library,
                     importer: ImportService(library: library, store: store, notices: notices, usage: usage),
                     notices: notices)
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Drops `urls` on one fresh library and picks them in another, and
    /// returns both outcomes and both banners.
    private func dropAndPick(_ urls: [URL]) async throws
        -> (dropped: ImportOutcome, picked: ImportOutcome, dropBanner: String?, pickBanner: String?, dropStack: Stack) {
        let dropStack = try makeStack()
        let pickStack = try makeStack()
        let dropped = await WADDrop.importDropped(urls, into: dropStack.importer)
        let picked = await pickStack.importer.importFiles(at: urls, from: .picker)
        return (dropped, picked, dropStack.notices.current, pickStack.notices.current, dropStack)
    }

    func testADroppedWADIsImported() async throws {
        let wad = try write("sunlust.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))

        let result = try await dropAndPick([wad])

        XCTAssertEqual(result.dropped.imported, ["sunlust"])
        XCTAssertTrue(result.dropped.rejected.isEmpty)
        XCTAssertEqual(try result.dropStack.library.allWADs().filter { !$0.isBundled }.map(\.kindRaw),
                       [WADKind.pwad.rawValue])
        XCTAssertEqual(result.dropped, result.picked)
        XCTAssertNotNil(result.dropBanner)
        XCTAssertEqual(result.dropBanner, result.pickBanner)
    }

    func testAnUnsupportedFileIsRejectedWithThePickerPathsNotice() async throws {
        let text = try write("readme.txt", Data("not a game".utf8))

        let result = try await dropAndPick([text])

        XCTAssertTrue(result.dropped.imported.isEmpty)
        XCTAssertEqual(result.dropped.rejected, ["readme.txt": "Unsupported file type."])
        XCTAssertEqual(result.dropped, result.picked)
        XCTAssertNotNil(result.dropBanner)
        XCTAssertEqual(result.dropBanner, result.pickBanner)
        // Like the picker, a drop leaves a rejected file where it was: the
        // player still has it, and it is not the library's to move.
        XCTAssertFalse(ImportRoute.drop.quarantinesRejects)
        XCTAssertTrue(FileManager.default.fileExists(atPath: text.path))
        XCTAssertFalse(result.dropBanner?.contains("Import Failed") ?? true)
    }

    func testSeveralFilesAreHandledInOneDrop() async throws {
        let wad = try write("sunlust.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let deh = try write("patch.deh", Data("Patch File for DeHackEd v3.0\n".utf8))
        let pk3 = try write("mod.pk3", Data("PK\u{3}\u{4}".utf8))

        let result = try await dropAndPick([wad, deh, pk3])

        XCTAssertEqual(Set(result.dropped.imported), ["sunlust", "patch"])
        XCTAssertEqual(result.dropped.rejected, ["mod.pk3": ImportFileType.refusedReason])
        XCTAssertEqual(result.dropped, result.picked)
        // One banner for the whole drop, the one the picker gives for the
        // same three files.
        XCTAssertNotNil(result.dropBanner)
        XCTAssertEqual(result.dropBanner, result.pickBanner)
    }

    /// The system takes its copy of a dropped file back as soon as it hands
    /// it over, so `stage` keeps one of its own under the same name, and the
    /// handler removes it once imported.
    func testAStagedCopyKeepsItsNameAndIsRemovedOnceImported() async throws {
        let original = try write("sunlust.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let staged = try WADDrop.stage(original)
        try FileManager.default.removeItem(at: original)

        XCTAssertEqual(staged.lastPathComponent, "sunlust.wad")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))

        let stack = try makeStack()
        let outcome = await WADDrop.importDropped([staged], into: stack.importer)

        XCTAssertEqual(outcome.imported, ["sunlust"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    /// A URL the handler did not stage is the caller's, and stays.
    func testAFileOutsideTheStagingFolderIsLeftInPlace() async throws {
        let wad = try write("sunlust.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let stack = try makeStack()

        _ = await WADDrop.importDropped([wad], into: stack.importer)

        XCTAssertTrue(FileManager.default.fileExists(atPath: wad.path))
    }
}
