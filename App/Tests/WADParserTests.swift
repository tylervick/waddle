import XCTest
@testable import BoomBox

/// Builds a syntactically valid WAD in memory.
/// Layout: 12-byte header | lump directory (16 bytes/lump, zero data).
func makeWAD(magic: String, lumps: [String]) -> Data {
    var data = Data(magic.utf8)                                // 0-3 magic
    data.append(contentsOf: withUnsafeBytes(of: Int32(lumps.count).littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: Int32(12).littleEndian, Array.init)) // dir right after header
    for name in lumps {
        data.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian, Array.init)) // filepos
        data.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian, Array.init)) // size
        var bytes = Array(name.utf8.prefix(8))
        bytes.append(contentsOf: Array(repeating: 0, count: 8 - bytes.count))
        data.append(contentsOf: bytes)
    }
    return data
}

final class WADParserTests: XCTestCase {
    func testParsesIWADMagic() throws {
        let wad = try WADParser.parse(makeWAD(magic: "IWAD", lumps: ["E1M1", "THINGS"]))
        XCTAssertEqual(wad.kind, .iwad)
        XCTAssertEqual(wad.lumpNames, ["E1M1", "THINGS"])
    }

    func testParsesPWADMagic() throws {
        let wad = try WADParser.parse(makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        XCTAssertEqual(wad.kind, .pwad)
    }

    func testRejectsBadMagic() {
        XCTAssertThrowsError(try WADParser.parse(makeWAD(magic: "JUNK", lumps: []))) {
            XCTAssertEqual($0 as? WADParseError, .badMagic)
        }
    }

    func testRejectsTruncatedFile() {
        XCTAssertThrowsError(try WADParser.parse(Data("IW".utf8))) {
            XCTAssertEqual($0 as? WADParseError, .tooSmall)
        }
    }

    func testRejectsDirectoryOutOfBounds() {
        var data = Data("PWAD".utf8)
        data.append(contentsOf: withUnsafeBytes(of: Int32(1000).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: Int32(999_999).littleEndian, Array.init))
        XCTAssertThrowsError(try WADParser.parse(data)) {
            XCTAssertEqual($0 as? WADParseError, .corruptDirectory)
        }
    }

    func testTextFileRenamedToWadIsRejected() {
        XCTAssertThrowsError(try WADParser.parse(Data("This is not a wad at all, just text".utf8))) {
            XCTAssertEqual($0 as? WADParseError, .badMagic)
        }
    }

    func testMapFormatEpisodic() {
        XCTAssertEqual(WADParser.mapFormat(of: ["E1M1", "THINGS", "E1M2"]), .episodic)
    }

    func testMapFormatMapXX() {
        XCTAssertEqual(WADParser.mapFormat(of: ["MAP01", "THINGS", "MAP32"]), .mapXX)
    }

    func testMapFormatNone() {
        XCTAssertEqual(WADParser.mapFormat(of: ["DEHACKED", "TEXTURE1"]), .none)
    }

    func testGameFamily() {
        XCTAssertEqual(WADParser.gameFamily(of: ["MAP01"]), .doom2)
        XCTAssertEqual(WADParser.gameFamily(of: ["E2M4"]), .doom1)
        XCTAssertEqual(WADParser.gameFamily(of: ["TEXTURE1"]), .unknown)
    }

    func testParsesDataSliceWithNonZeroStartIndex() throws {
        var padded = Data(repeating: 0xFF, count: 20)
        padded.append(makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let slice = padded[20...]
        XCTAssertNotEqual(slice.startIndex, 0)
        let wad = try WADParser.parse(slice)
        XCTAssertEqual(wad.kind, .pwad)
        XCTAssertEqual(wad.lumpNames, ["MAP01"])
    }

    func testNonASCIIDigitsAreNotMapLumps() {
        XCTAssertEqual(WADParser.mapFormat(of: ["MAP٢²"]), .none)
        XCTAssertEqual(WADParser.mapFormat(of: ["E٢M²"]), .none)
    }
}
