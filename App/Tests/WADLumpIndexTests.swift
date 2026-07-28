import XCTest
@testable import WADdle

final class WADLumpIndexTests: XCTestCase {
    // Builds a minimal WAD: header + one lump "DATA" (bytes) + directory.
    private func makeWAD(lumpName: String, lump: [UInt8]) -> Data {
        var d = Data()
        func i32(_ v: Int) -> Data { withUnsafeBytes(of: Int32(v).littleEndian) { Data($0) } }
        let headerSize = 12
        let lumpOffset = headerSize
        let dirOffset = headerSize + lump.count
        d.append(contentsOf: Array("IWAD".utf8))       // magic
        d.append(i32(1))                                // numLumps
        d.append(i32(dirOffset))                        // dirOffset
        d.append(contentsOf: lump)                      // lump bytes at offset 12
        d.append(i32(lumpOffset))                       // dir entry: filepos
        d.append(i32(lump.count))                       // dir entry: size
        var name8 = Array(lumpName.utf8); name8 += Array(repeating: 0, count: 8 - name8.count)
        d.append(contentsOf: name8)                     // dir entry: name (8, NUL-padded)
        return d
    }

    func testFindsLumpOffsetAndSize() throws {
        let wad = makeWAD(lumpName: "DATA", lump: [0xAA, 0xBB, 0xCC])
        let index = try WADLumpIndex(wad: wad)
        let os = index.offsetSize(of: "DATA")
        XCTAssertEqual(os?.offset, 12)
        XCTAssertEqual(os?.size, 3)
        XCTAssertNil(index.offsetSize(of: "NOPE"))
    }

    func testLumpNameIsUppercasedAndLookupCaseInsensitive() throws {
        let wad = makeWAD(lumpName: "TITLEPIC", lump: [1, 2])
        let index = try WADLumpIndex(wad: wad)
        XCTAssertNotNil(index.offsetSize(of: "titlepic"))
    }

    func testReadsLumpBytesFromFileHandle() throws {
        let wad = makeWAD(lumpName: "DATA", lump: [0xAA, 0xBB, 0xCC])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wad")
        try wad.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let index = try WADLumpIndex.read(from: url)
        XCTAssertEqual(try WADLumpIndex.lumpData("DATA", at: url, index: index).map(Array.init), [0xAA, 0xBB, 0xCC])
    }

    func testRejectsBadMagic() {
        var d = Data("XXXX".utf8); d.append(Data(repeating: 0, count: 8))
        XCTAssertThrowsError(try WADLumpIndex(wad: d))
    }

    func testSkipsEntriesWithNegativeOffsetOrSize() throws {
        // A corrupt WAD stores filepos = -1 for its one entry. Parsing must not
        // trap, and the malformed entry must be skipped (never surfaced).
        func i32(_ v: Int32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        var d: [UInt8] = Array("IWAD".utf8) + i32(1) + i32(12)   // numLumps=1, dirOffset=12
        d += i32(-1) + i32(3)                                    // filepos=-1, size=3
        var name = Array("BAD".utf8); name += Array(repeating: 0, count: 8 - name.count)
        d += name
        let index = try WADLumpIndex(wad: Data(d))               // must not crash
        XCTAssertNil(index.offsetSize(of: "BAD"), "negative-offset entry must be skipped")
    }
}
