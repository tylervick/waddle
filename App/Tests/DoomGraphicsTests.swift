import XCTest
@testable import WADdle

final class DoomGraphicsTests: XCTestCase {
    func testPaletteReadsFirst256TriplesAsOpaqueRGBA() {
        var playpal = Data([10, 20, 30])                       // index 0
        playpal.append(Data(repeating: 0, count: 768 - 3))     // pad to a full palette
        let pal = DoomGraphics.palette(from: playpal)
        XCTAssertEqual(pal?.count, 256 * 4)
        XCTAssertEqual(pal.map { Array($0[0..<4]) }, [10, 20, 30, 255])
    }

    func testPaletteRejectsShortData() {
        XCTAssertNil(DoomGraphics.palette(from: Data([1, 2, 3])))
    }

    // A synthetic 1x2 picture: column 0 has one post covering both rows with
    // palette indices 3 then 7.
    func testDecodesSinglePostColumn() {
        // header: width=1, height=2, left=0, top=0
        var lump = Data([0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00])
        // columnofs[0] = 12 (u32)
        lump.append(Data([0x0C, 0x00, 0x00, 0x00]))
        // column @12: topdelta=0, length=2, unused, pix[3,7], unused, end=0xFF
        lump.append(Data([0x00, 0x02, 0x00, 0x03, 0x07, 0x00, 0xFF]))

        var pal = [UInt8](repeating: 0, count: 256 * 4)
        pal[3 * 4 + 0] = 30; pal[3 * 4 + 1] = 30; pal[3 * 4 + 2] = 30; pal[3 * 4 + 3] = 255
        pal[7 * 4 + 0] = 70; pal[7 * 4 + 1] = 70; pal[7 * 4 + 2] = 70; pal[7 * 4 + 3] = 255

        let bmp = DoomGraphics.decodePicture(lump, palette: pal)
        XCTAssertEqual(bmp?.width, 1)
        XCTAssertEqual(bmp?.height, 2)
        // (0,0) = idx3, (0,1) = idx7
        XCTAssertEqual(bmp.map { Array($0.rgba[0..<4]) }, [30, 30, 30, 255])
        XCTAssertEqual(bmp.map { Array($0.rgba[4..<8]) }, [70, 70, 70, 255])
    }

    func testRejectsBogusPicture() {
        XCTAssertNil(DoomGraphics.decodePicture(Data([0xFF, 0xFF]), palette: [UInt8](repeating: 0, count: 1024)))
    }

    func testRejectsColumnOffsetInsideHeaderTable() {
        // width=1,height=1; the single column offset points at 0 (into the
        // header), which is malformed -> nil, so the caller uses generated art.
        var lump = Data([0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00])
        lump.append(Data([0x00, 0x00, 0x00, 0x00]))   // columnofs[0] = 0 (< 8 + 1*4)
        lump.append(Data([0x00, 0x01, 0x00, 0x05, 0x00, 0xFF]))
        XCTAssertNil(DoomGraphics.decodePicture(lump, palette: [UInt8](repeating: 0, count: 1024)))
    }
}
