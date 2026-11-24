import XCTest
import ZIPFoundation
@testable import Waddle

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
    // MARK: Whole-archive caps (#516)

    /// Builds a zip of `count` entries of `size` zero bytes each, named
    /// `prefix0.ext`, `prefix1.ext`, ...
    private func makeZip(count: Int, size: Int, ext: String = "wad", extra: [String: String] = [:]) throws -> URL {
        let zipURL = tmp.appendingPathComponent("\(UUID().uuidString).zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let data = Data(repeating: 0, count: size)
        for index in 0..<count {
            try archive.addEntry(with: "e\(index).\(ext)", type: .file, uncompressedSize: Int64(size),
                                 compressionMethod: .deflate,
                                 provider: { pos, len in data.subdata(in: Int(pos)..<Int(pos) + len) })
        }
        for (path, contents) in extra {
            let bytes = Data(contents.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count),
                                 provider: { pos, len in bytes.subdata(in: Int(pos)..<Int(pos) + len) })
        }
        return zipURL
    }

    /// Runs `body`, which must throw `refusal`, and checks it left no new
    /// `wad-import-*` directory behind.
    private func assertRefused(_ refusal: ZipExtractor.Refusal, file: StaticString = #filePath, line: UInt = #line,
                               _ body: () throws -> Void) throws {
        let before = try ZipFixtures.importDirectories()
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? ZipExtractor.Refusal, refusal, file: file, line: line)
        }
        XCTAssertEqual(try ZipFixtures.importDirectories(), before, "nothing left in tmp", file: file, line: line)
    }

    func testTotalBytesCapRefusesTheArchiveOverItAndTakesOneAtIt() throws {
        let mib: Int64 = 1024 * 1024
        let limits = ZipExtractor.Limits(totalBytes: mib)
        let three = try makeZip(count: 3, size: 512 * 1024)
        try assertRefused(.tooLarge(limit: mib)) {
            _ = try ZipExtractor.extractGameFiles(from: three, limits: limits)
        }

        let two = try makeZip(count: 2, size: 512 * 1024)
        let result = try ZipExtractor.extractGameFiles(from: two, limits: limits)
        defer { try? FileManager.default.removeItem(at: result.dir) }
        XCTAssertEqual(result.files.count, 2)
    }

    /// The total cap is checked against the declared sizes before anything
    /// is written: an archive that declares more than the cap is refused
    /// even when its entries would really unpack to less.
    func testTotalBytesCapIsCheckedAgainstTheDeclaredSizesFirst() throws {
        let zip = try ZipFixtures.lyingZip(in: tmp, realSize: 16, declaredSize: 2048)
        try assertRefused(.tooLarge(limit: 1024)) {
            _ = try ZipExtractor.extractGameFiles(from: zip, limits: ZipExtractor.Limits(totalBytes: 1024))
        }
    }

    /// An entry skipped for being over the per-entry cap is not extracted,
    /// so it spends nothing of the total.
    func testAnOversizeEntrySpendsNothingOfTheTotal() throws {
        let zip = try makeZip(count: 1, size: 100, extra: ["big.wad": String(repeating: "x", count: 1000)])
        let result = try ZipExtractor.extractGameFiles(
            from: zip, limits: ZipExtractor.Limits(entryBytes: 500, totalBytes: 500))
        defer { try? FileManager.default.removeItem(at: result.dir) }
        XCTAssertEqual(result.files.map(\.name), ["e0.wad"])
        XCTAssertEqual(result.skippedOversize, ["big.wad"])
    }

    func testGameFileCapRefusesTheArchiveOverItAndTakesOneAtIt() throws {
        let limits = ZipExtractor.Limits(gameEntries: 3)
        // Other files are not game files and do not count.
        let atCap = try makeZip(count: 3, size: 4, extra: ["a.txt": "a", "b.txt": "b"])
        let result = try ZipExtractor.extractGameFiles(from: atCap, limits: limits)
        defer { try? FileManager.default.removeItem(at: result.dir) }
        XCTAssertEqual(result.files.count, 3)

        let over = try makeZip(count: 3, size: 4, extra: ["patch.deh": "Patch"])
        try assertRefused(.tooManyGameFiles(limit: 3)) {
            _ = try ZipExtractor.extractGameFiles(from: over, limits: limits)
        }
    }

    func testEntryCapRefusesTheArchiveOverItAndTakesOneAtIt() throws {
        let limits = ZipExtractor.Limits(entries: 3)
        let atCap = try makeZip(count: 1, size: 4, extra: ["a.txt": "a", "b.txt": "b"])
        let result = try ZipExtractor.extractGameFiles(from: atCap, limits: limits)
        defer { try? FileManager.default.removeItem(at: result.dir) }
        XCTAssertEqual(result.files.count, 1)

        let over = try makeZip(count: 1, size: 4, extra: ["a.txt": "a", "b.txt": "b", "c.txt": "c"])
        try assertRefused(.tooManyEntries(limit: 3)) {
            _ = try ZipExtractor.extractGameFiles(from: over, limits: limits)
        }
    }

    /// A header that declares fewer bytes than the entry inflates to: the
    /// declared size passes every cap, and extraction stops at the real
    /// bytes instead of trusting it.
    func testAnEntryLargerThanItsHeaderSaysIsStopped() throws {
        let zip = try ZipFixtures.lyingZip(in: tmp, realSize: 64 * 1024, declaredSize: 16)
        var entries = try Archive(url: zip, accessMode: .read).makeIterator()
        let entry = try XCTUnwrap(entries.next())
        XCTAssertEqual(entry.uncompressedSize, 16, "the fixture's header lies")

        try assertRefused(.sizeMismatch) {
            _ = try ZipExtractor.extractGameFiles(from: zip)
        }
    }

    func testPK3MarkersAreTheRootLumpsAndFoldersAPK3Keeps() {
        for path in ["DECORATE", "decorate.txt", "ZSCRIPT.zs", "GAMEINFO.txt", "MAPINFO", "zmapinfo.txt",
                     "maps/MAP01.wad", "maps/", "Sprites/x.png", "textures/", "sounds/s.ogg", "graphics/g.png"] {
            XCTAssertTrue(ZipExtractor.isPK3Marker(path), path)
        }
        for path in ["map.wad", "map.txt", "mod/DECORATE.txt", "mod/maps/MAP01.wad", "decorate/", "mapsx/a.wad",
                     "readme.txt"] {
            XCTAssertFalse(ZipExtractor.isPK3Marker(path), path)
        }
    }

    func testAPK3LayoutIsRefusedOnlyWhenAsked() throws {
        let zip = try makeZip(entries: ["maps/MAP01.wad": "PWAD", "DECORATE.txt": "actor X {}"])
        try assertRefused(.pk3Layout) {
            _ = try ZipExtractor.extractGameFiles(from: zip, limits: ZipExtractor.Limits(), refusingPK3Layout: true)
        }

        let result = try ZipExtractor.extractGameFiles(from: zip)
        defer { try? FileManager.default.removeItem(at: result.dir) }
        XCTAssertEqual(result.files.map(\.name), ["MAP01.wad"], "a file that says it is a zip is taken as one")
    }

    func testRefusalReasonsNameTheLimit() {
        XCTAssertEqual(ZipExtractor.Refusal.tooLarge(limit: ZipExtractor.maxTotalBytes).reason,
                       "This zip unpacks to more than 1 GB, the import limit.")
        XCTAssertEqual(ZipExtractor.Refusal.tooManyGameFiles(limit: ZipExtractor.maxGameEntries).reason,
                       "This zip holds more than 64 WAD and DEH files, the import limit.")
        XCTAssertEqual(ZipExtractor.Refusal.tooManyEntries(limit: ZipExtractor.maxEntries).reason,
                       "This zip holds more than 10000 files, the import limit.")
        XCTAssertEqual(ZipExtractor.Refusal.pk3Layout.reason, ImportFileType.refusedReason)
    }
}

/// Zip fixtures shared by the extractor and import tests.
enum ZipFixtures {
    /// The `wad-import-*` directories in tmp right now.
    static func importDirectories() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("wad-import-") })
    }

    /// A zip in `dir` holding one deflated `lie.wad` of `realSize` zero
    /// bytes whose local and central headers both declare `declaredSize`.
    static func lyingZip(in dir: URL, realSize: Int, declaredSize: UInt32,
                         name: String = "lie.zip") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let archive = try Archive(url: url, accessMode: .create)
        let data = Data(repeating: 0, count: realSize)
        try archive.addEntry(with: "lie.wad", type: .file, uncompressedSize: Int64(realSize),
                             compressionMethod: .deflate,
                             provider: { pos, len in data.subdata(in: Int(pos)..<Int(pos) + len) })
        var bytes = [UInt8](try Data(contentsOf: url))
        func patch(signature: [UInt8], sizeOffset: Int) {
            guard let start = (0...(bytes.count - 4)).first(where: { Array(bytes[$0..<$0 + 4]) == signature })
            else { return }
            withUnsafeBytes(of: declaredSize.littleEndian) { size in
                for (index, byte) in size.enumerated() { bytes[start + sizeOffset + index] = byte }
            }
        }
        patch(signature: [0x50, 0x4B, 0x03, 0x04], sizeOffset: 22)   // local file header
        patch(signature: [0x50, 0x4B, 0x01, 0x02], sizeOffset: 24)   // central directory header
        try Data(bytes).write(to: url)
        return url
    }
}
