import XCTest
@testable import BoomBox

final class WADStoreTests: XCTestCase {
    var tmp: URL!
    var store: WADStore!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = WADStore(directory: tmp.appendingPathComponent("WADs", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func writeSource(_ name: String, _ contents: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testStoresFileAndComputesSHA1() throws {
        let src = try writeSource("a.wad", "hello")
        let stored = try store.store(fileAt: src, preferredName: "a.wad")
        XCTAssertEqual(stored.filename, "a.wad")
        XCTAssertFalse(stored.isDuplicate)
        // shasum -a1 of "hello"
        XCTAssertEqual(stored.sha1, "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(forFilename: "a.wad").path))
    }

    func testDuplicateContentIsDeduplicated() throws {
        _ = try store.store(fileAt: writeSource("a.wad", "same"), preferredName: "a.wad")
        let dup = try store.store(fileAt: writeSource("b.wad", "same"), preferredName: "b.wad")
        XCTAssertTrue(dup.isDuplicate)
        XCTAssertEqual(dup.filename, "a.wad")   // points at the existing file
    }

    func testNameCollisionWithDifferentContentGetsSuffix() throws {
        _ = try store.store(fileAt: writeSource("x1.wad", "one"), preferredName: "map.wad")
        let second = try store.store(fileAt: writeSource("x2.wad", "two"), preferredName: "map.wad")
        XCTAssertEqual(second.filename, "map (2).wad")
        XCTAssertFalse(second.isDuplicate)
    }

    func testFilenameWithSpacesSurvives() throws {
        let src = try writeSource("Eviternity II.wad", "big")
        let stored = try store.store(fileAt: src, preferredName: "Eviternity II.wad")
        XCTAssertEqual(stored.filename, "Eviternity II.wad")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(forFilename: stored.filename).path))
    }

    func testDelete() throws {
        _ = try store.store(fileAt: writeSource("a.wad", "gone"), preferredName: "a.wad")
        try store.delete(filename: "a.wad")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(forFilename: "a.wad").path))
    }
}
