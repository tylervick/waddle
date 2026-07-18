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

    // MARK: oversize zip entries

    /// A zip whose only game-file entry blows the size cap: nothing gets
    /// extracted, so the old "no files extracted" guard rejected the zip
    /// once under its own name. The fix moves that bookkeeping onto the
    /// skipped entry itself, but the net behavior a caller cares about —
    /// the zip is rejected and nothing imports — must stay the same.
    func testOversizeOnlyZipStillRejectedWithoutImporting() throws {
        let big = Data(repeating: 0, count: 64)
        let zipURL = tmp.appendingPathComponent("big-only.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: "big.wad", type: .file,
                             uncompressedSize: Int64(big.count),
                             provider: { pos, size in big.subdata(in: Int(pos)..<Int(pos) + size) })
        importer.maxZipEntryBytes = 5

        let outcome = importer.importFiles(at: [zipURL])

        XCTAssertTrue(outcome.imported.isEmpty)
        // The reason string reports the cap actually in effect; these tests
        // shrink it below 1 MB, which integer-divides down to "0 MB".
        XCTAssertEqual(outcome.rejected["big.wad"], "Entry exceeds the 0 MB import limit.")
    }

    /// A zip with one importable wad and one entry over the cap: the valid
    /// file must still import, AND the oversize entry must be recorded as
    /// its own rejection rather than silently dropped. Previously the drop
    /// happened because the "no files extracted" guard never fires once
    /// *something* extracted — the skipped entry's existence just vanished,
    /// and (via adoptLooseFiles) the zip carrying it got deleted as a clean
    /// import.
    func testMixedZipImportsValidEntryAndRejectsOversizeEntry() throws {
        let wadData = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        let big = Data(repeating: 0, count: wadData.count + 1000)
        let zipURL = tmp.appendingPathComponent("mixed.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: "ok.wad", type: .file,
                             uncompressedSize: Int64(wadData.count),
                             provider: { pos, size in wadData.subdata(in: Int(pos)..<Int(pos) + size) })
        try archive.addEntry(with: "big.wad", type: .file,
                             uncompressedSize: Int64(big.count),
                             provider: { pos, size in big.subdata(in: Int(pos)..<Int(pos) + size) })
        importer.maxZipEntryBytes = Int64(wadData.count)

        let outcome = importer.importFiles(at: [zipURL])

        XCTAssertEqual(outcome.imported, ["ok"])
        XCTAssertEqual(outcome.rejected["big.wad"], "Entry exceeds the 0 MB import limit.")
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

    /// Plan 2 consciously accepted "import wins, delete the zip" when a
    /// candidate's *other* entries are simply corrupt (see the all-fail
    /// case above) — those bytes were never recoverable anyway. An oversize
    /// entry is different: it's legitimate content that only failed
    /// because of the import-time size cap, so deleting the zip would
    /// destroy the only surviving copy. The adopt path must quarantine
    /// instead, even though ok.wad did import successfully.
    func testAdoptLooseFilesQuarantinesMixedZipWithOversizeEntryEvenThoughSomethingImported() async throws {
        let docs = URL.documentsDirectory
        let name = "mixed-\(UUID().uuidString).zip"
        let zipURL = docs.appendingPathComponent(name)
        let importFailedURL = docs.appendingPathComponent("Import Failed").appendingPathComponent(name)
        defer {
            try? FileManager.default.removeItem(at: zipURL)
            try? FileManager.default.removeItem(at: importFailedURL)
        }

        let wadData = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        let big = Data(repeating: 0, count: wadData.count + 1000)
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: "ok.wad", type: .file,
                             uncompressedSize: Int64(wadData.count),
                             provider: { pos, size in wadData.subdata(in: Int(pos)..<Int(pos) + size) })
        try archive.addEntry(with: "big.wad", type: .file,
                             uncompressedSize: Int64(big.count),
                             provider: { pos, size in big.subdata(in: Int(pos)..<Int(pos) + size) })
        importer.maxZipEntryBytes = Int64(wadData.count)

        let outcome = await importer.adoptLooseFiles()

        XCTAssertEqual(outcome.imported, ["ok"])
        XCTAssertEqual(outcome.rejected["big.wad"], "Entry exceeds the 0 MB import limit.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: zipURL.path),
                       "zip should have been moved out of Documents")
        XCTAssertTrue(FileManager.default.fileExists(atPath: importFailedURL.path),
                      "zip should be quarantined, not deleted, once it contributed an oversize rejection")
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
