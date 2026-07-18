import XCTest
import ZIPFoundation
@testable import BoomBox

final class ZipExtractorTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Builds a zip containing entries at the given paths.
    private func makeZip(entries: [String: String]) throws -> URL {
        let zipURL = tmp.appendingPathComponent("\(UUID().uuidString).zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        for (path, contents) in entries {
            let data = Data(contents.utf8)
            try archive.addEntry(with: path, type: .file,
                                 uncompressedSize: Int64(data.count),
                                 provider: { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            })
        }
        return zipURL
    }

    func testExtractsWadAndDehIgnoresJunk() throws {
        let zip = try makeZip(entries: [
            "cool.wad": "PWAD....",
            "patch.deh": "Patch File for DeHackEd",
            "readme.txt": "ignore me",
        ])
        let result = try ZipExtractor.extractGameFiles(from: zip)
        defer { try? FileManager.default.removeItem(at: result.dir) }
        XCTAssertEqual(Set(result.files.map(\.name)), ["cool.wad", "patch.deh"])
    }

    func testExtractsFromNestedDirectories() throws {
        // Mirrors sunlust.zip's real layout: sunlust/sunlust.wad
        let zip = try makeZip(entries: ["sunlust/sunlust.wad": "PWAD....",
                                        "sunlust/sunlust.txt": "notes"])
        let result = try ZipExtractor.extractGameFiles(from: zip)
        defer { try? FileManager.default.removeItem(at: result.dir) }
        XCTAssertEqual(result.files.map(\.name), ["sunlust.wad"])
    }

    func testZipWithNoGameFilesReturnsEmpty() throws {
        let zip = try makeZip(entries: ["readme.txt": "nothing here"])
        let result = try ZipExtractor.extractGameFiles(from: zip)
        defer { try? FileManager.default.removeItem(at: result.dir) }
        XCTAssertTrue(result.files.isEmpty)
    }

    func testOversizeEntriesAreSkippedAndReported() throws {
        let zip = try makeZip(entries: ["big.wad": "0123456789", "ok.wad": "PWAD"])
        let result = try ZipExtractor.extractGameFiles(from: zip, maxEntryBytes: 5)
        defer { try? FileManager.default.removeItem(at: result.dir) }
        XCTAssertEqual(result.files.map(\.name), ["ok.wad"])
        XCTAssertEqual(result.skippedOversize, ["big.wad"])
    }

    func testDuplicateBasenamesGetUniquified() throws {
        let zip = try makeZip(entries: [
            "a/map.wad": "content1",
            "b/map.wad": "content2",
        ])
        let result = try ZipExtractor.extractGameFiles(from: zip)
        defer { try? FileManager.default.removeItem(at: result.dir) }

        XCTAssertEqual(result.files.count, 2)
        XCTAssertEqual(Set(result.files.map(\.name)), ["map.wad", "map (2).wad"])

        // Verify distinct contents preserved
        let content1 = try Data(contentsOf: result.files[0].url)
        let content2 = try Data(contentsOf: result.files[1].url)
        XCTAssertNotEqual(content1, content2)
        XCTAssertTrue([content1, content2].contains(Data("content1".utf8)) ||
                     [content1, content2].contains(Data("content2".utf8)))
    }
}
