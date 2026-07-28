import XCTest
@testable import WADdle

final class WADArtworkTests: XCTestCase {
    // Assemble a WAD from named lumps (offsets computed).
    private func makeWAD(_ lumps: [(String, [UInt8])]) -> Data {
        func i32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: Int32(v).littleEndian) { Array($0) } }
        var body: [UInt8] = []; var dir: [UInt8] = []
        var offset = 12
        for (name, bytes) in lumps {
            dir += i32(offset) + i32(bytes.count)
            var n = Array(name.utf8); n += Array(repeating: 0, count: 8 - n.count); dir += n
            body += bytes; offset += bytes.count
        }
        var out = Array("IWAD".utf8) + i32(lumps.count) + i32(12 + body.count)
        out += body + dir
        return Data(out)
    }

    func testDecodesSyntheticTitlepic() async throws {
        // 1x2 picture, indices 3 then 7; palette makes idx7 = pure red.
        let pic: [UInt8] = [0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
                            0x0C, 0x00, 0x00, 0x00,
                            0x00, 0x02, 0x00, 0x03, 0x07, 0x00, 0xFF]
        var playpal = [UInt8](repeating: 0, count: 768)
        playpal[7 * 3 + 0] = 255  // idx7 red
        let wad = makeWAD([("TITLEPIC", pic), ("PLAYPAL", playpal)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wad")
        try wad.write(to: url); defer { try? FileManager.default.removeItem(at: url) }

        let key = "titleart-test-\(UUID().uuidString)"
        let img = await WADArtwork.titleImage(candidates: [url], cacheKey: key)
        XCTAssertNotNil(img)
        XCTAssertEqual(img?.width, 1)
        XCTAssertEqual(img?.height, 2)
        WADArtwork.clearCache(key: key)   // test hygiene
    }

    func testReturnsNilWhenNoTitlepic() async throws {
        let wad = makeWAD([("PLAYPAL", [UInt8](repeating: 0, count: 768))])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wad")
        try wad.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let img = await WADArtwork.titleImage(candidates: [url], cacheKey: "none-\(UUID().uuidString)")
        XCTAssertNil(img)
    }

    // Optional real-WAD spot check (Task 3, Step 5): skips where the bundled
    // Freedoom resource isn't present in the test host.
    func testDecodesRealFreedoomTitlepic() async throws {
        let url = Bundle.main.resourceURL!
            .appendingPathComponent("GameData", isDirectory: true)
            .appendingPathComponent("freedoom1.wad")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))

        let key = "titleart-freedoom-\(UUID().uuidString)"
        let img = await WADArtwork.titleImage(candidates: [url], cacheKey: key)
        XCTAssertNotNil(img)
        XCTAssertEqual(img?.width, 320)
        WADArtwork.clearCache(key: key)
    }
}
