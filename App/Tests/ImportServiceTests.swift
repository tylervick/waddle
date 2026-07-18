import SwiftData
import XCTest
import ZIPFoundation
@testable import BoomBox

@MainActor
final class ImportServiceTests: XCTestCase {
    var importer: ImportService!
    var library: LibraryService!
    var tmp: URL!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, configurations: config)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = WADStore(directory: tmp.appendingPathComponent("WADs", isDirectory: true))
        library = LibraryService(context: ModelContext(container), store: store)
        importer = ImportService(library: library, store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testImportsValidPWAD() throws {
        let url = try write("sunlust.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let outcome = importer.importFiles(at: [url])
        XCTAssertEqual(outcome.imported, ["sunlust"])
        XCTAssertEqual(try library.allWADs().first?.kindRaw, WADKind.pwad.rawValue)
        XCTAssertEqual(try library.allWADs().first?.gameFamilyRaw, "doom2")
    }

    func testRejectsInvalidWadWithReason() throws {
        let url = try write("fake.wad", Data("not a wad".utf8))
        let outcome = importer.importFiles(at: [url])
        XCTAssertTrue(outcome.imported.isEmpty)
        XCTAssertNotNil(outcome.rejected["fake.wad"])
        XCTAssertTrue(try library.allWADs().isEmpty)
    }

    func testDuplicateImportReported() throws {
        let data = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        _ = importer.importFiles(at: [try write("a.wad", data)])
        let outcome = importer.importFiles(at: [try write("b.wad", data)])
        XCTAssertEqual(outcome.duplicates.count, 1)
        XCTAssertEqual(try library.allWADs().count, 1)
    }

    func testImportsDEHByExtension() throws {
        let url = try write("tweaks.deh", Data("Patch File for DeHackEd 3.0".utf8))
        let outcome = importer.importFiles(at: [url])
        XCTAssertEqual(outcome.imported, ["tweaks"])
        XCTAssertEqual(try library.allWADs().first?.kindRaw, WADKind.deh.rawValue)
    }

    func testImportsWadsOutOfZip() throws {
        // Build a zip with a nested wad + junk, like real downloads.
        let zipURL = tmp.appendingPathComponent("dl.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let wadData = makeWAD(magic: "PWAD", lumps: ["E1M1"])
        try archive.addEntry(with: "release/map.wad", type: .file,
                             uncompressedSize: Int64(wadData.count),
                             provider: { pos, size in
            wadData.subdata(in: Int(pos)..<Int(pos) + size)
        })
        let outcome = importer.importFiles(at: [zipURL])
        XCTAssertEqual(outcome.imported, ["map"])
        XCTAssertEqual(try library.allWADs().first?.gameFamilyRaw, "doom1")
    }

    // MARK: adoptLooseFiles

    func testAdoptLooseFilesMovesRejectedFilesToImportFailed() async throws {
        // adoptLooseFiles scans the real app Documents directory (Files-app
        // drop zone), not the tmp WADStore dir, so the fixture has to live
        // there too.
        let docs = URL.documentsDirectory
        let name = "junk-\(UUID().uuidString).wad"
        let junkURL = docs.appendingPathComponent(name)
        let importFailedURL = docs.appendingPathComponent("Import Failed").appendingPathComponent(name)
        try Data("not a wad".utf8).write(to: junkURL)
        defer {
            try? FileManager.default.removeItem(at: junkURL)
            try? FileManager.default.removeItem(at: importFailedURL)
        }

        let outcome = await importer.adoptLooseFiles()

        XCTAssertNotNil(outcome.rejected[name])
        XCTAssertFalse(FileManager.default.fileExists(atPath: junkURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importFailedURL.path))
    }

    func testAdoptLooseFilesQuarantinesZipWhoseContentsAllFailImport() async throws {
        // The rejection from a corrupt inner .wad is recorded under the
        // inner file's own name ("corrupt.wad"), never the zip's — so the
        // zip-level keep/quarantine/delete decision can't be a lookup keyed
        // on the zip's own basename (it would never find a rejection there
        // and would wrongly delete the zip as if it had imported cleanly).
        let docs = URL.documentsDirectory
        let name = "bundle-\(UUID().uuidString).zip"
        let zipURL = docs.appendingPathComponent(name)
        let importFailedURL = docs.appendingPathComponent("Import Failed").appendingPathComponent(name)
        defer {
            try? FileManager.default.removeItem(at: zipURL)
            try? FileManager.default.removeItem(at: importFailedURL)
        }

        let archive = try Archive(url: zipURL, accessMode: .create)
        let badData = Data("not a wad".utf8)
        try archive.addEntry(with: "corrupt.wad", type: .file,
                             uncompressedSize: Int64(badData.count),
                             provider: { pos, size in
            badData.subdata(in: Int(pos)..<Int(pos) + size)
        })

        let outcome = await importer.adoptLooseFiles()

        XCTAssertFalse(outcome.rejected.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: zipURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importFailedURL.path))
    }

    // MARK: dedupe ordering

    func testDuplicateImportDoesNotWriteNewStoreFile() throws {
        let data = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        _ = importer.importFiles(at: [try write("a.wad", data)])
        let storeDir = tmp.appendingPathComponent("WADs", isDirectory: true)
        let before = try FileManager.default.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: nil).count

        _ = importer.importFiles(at: [try write("b.wad", data)])

        let after = try FileManager.default.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: nil).count
        XCTAssertEqual(after, before)
    }

    // MARK: repair when the stored file went missing

    func testReimportRestoresRowWhenStoredFileWasDeleted() throws {
        let data = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        let first = importer.importFiles(at: [try write("a.wad", data)])
        XCTAssertEqual(first.imported, ["a"])
        let wad = try XCTUnwrap(library.allWADs().first)
        try FileManager.default.removeItem(at: library.fileURL(for: wad))

        let second = importer.importFiles(at: [try write("b.wad", data)])

        XCTAssertEqual(second.imported, ["b"])
        XCTAssertTrue(second.duplicates.isEmpty)
        XCTAssertEqual(try library.allWADs().count, 1)
        let repaired = try XCTUnwrap(try library.wad(id: wad.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.fileURL(for: repaired).path))

        let storeDir = tmp.appendingPathComponent("WADs", isDirectory: true)
        let filesInStore = try FileManager.default.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(filesInStore.count, 1)
    }
}
