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
        XCTAssertEqual(try library.allWADs().first?.kindRaw, "PWAD")
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
        XCTAssertEqual(try library.allWADs().first?.kindRaw, "DEH")
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
}
