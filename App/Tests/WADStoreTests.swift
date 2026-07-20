import XCTest
@testable import WADdle

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

    // Adaptation (Plan 3 Task 7): store() used to rescan+rehash every file
    // already on disk to dedupe by content — that on-disk rescan is gone
    // (dedupe is the caller's job now: ImportService checks the library's
    // sha1 index, a single lookup, before ever calling store()). Two direct
    // store() calls with identical content now just produce two
    // independent files; this test is rewritten to assert that, replacing
    // the old testDuplicateContentIsDeduplicated which asserted the
    // opposite (on-disk dedup) behavior.
    func testStoreDoesNotDedupeOnDiskContentIsCallersJob() throws {
        let first = try store.store(fileAt: writeSource("a.wad", "same"), preferredName: "a.wad")
        let second = try store.store(fileAt: writeSource("b.wad", "same"), preferredName: "b.wad")
        XCTAssertFalse(second.isDuplicate)
        XCTAssertEqual(second.filename, "b.wad")
        XCTAssertNotEqual(first.filename, second.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(forFilename: "a.wad").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(forFilename: "b.wad").path))
    }

    func testStreamedHashMatchesInMemoryHash() throws {
        let src = try writeSource("h.wad", "streamed hashing test payload")
        let streamed = try WADStore.sha1(ofFileAt: src)
        let inMemory = WADStore.sha1(of: try Data(contentsOf: src))
        XCTAssertEqual(streamed, inMemory)
    }

    func testUnreadableSourceThrows() {
        XCTAssertThrowsError(try WADStore.sha1(
            ofFileAt: tmp.appendingPathComponent("nope.wad")))
        XCTAssertThrowsError(try store.store(
            fileAt: tmp.appendingPathComponent("nope.wad"), preferredName: "nope.wad")) {
            XCTAssertEqual($0 as? WADStoreError, .unreadable)
        }
    }

    func testPrecomputedHashSkipsRehash() throws {
        let src = try writeSource("p.wad", "content")
        let expected = WADStore.sha1(of: Data("content".utf8))
        let stored = try store.store(fileAt: src, preferredName: "p.wad",
                                     precomputedSHA1: expected)
        XCTAssertEqual(stored.sha1, expected)
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

    func testTraversalNamesAreConfinedToStoreDirectory() throws {
        let src = try writeSource("evil.wad", "payload")
        let stored = try store.store(fileAt: src, preferredName: "../../evil.wad")
        XCTAssertEqual(stored.filename, "evil.wad")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(forFilename: stored.filename).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.directory.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("evil.wad").path))
    }

    func testDegenerateNamesGetFallback() throws {
        let src = try writeSource("dot.wad", "x")
        let stored = try store.store(fileAt: src, preferredName: "..")
        XCTAssertEqual(stored.filename, "unnamed.wad")
    }
}
