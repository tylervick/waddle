import Foundation

/// Pure decoders for the two DOOM binary graphic formats needed for title art.
/// No CoreGraphics — returns raw RGBA so callers build platform images and
/// this stays fully unit-testable.
enum DoomGraphics {
    /// Palette 0 as 256 RGBA entries (1024 bytes, a=255) from a PLAYPAL lump.
    static func palette(from playpal: Data) -> [UInt8]? {
        guard playpal.count >= 768 else { return nil }
        let base = playpal.startIndex
        var out = [UInt8](repeating: 255, count: 256 * 4)
        for i in 0..<256 {
            out[i * 4 + 0] = playpal[base + i * 3 + 0]
            out[i * 4 + 1] = playpal[base + i * 3 + 1]
            out[i * 4 + 2] = playpal[base + i * 3 + 2]
        }
        return out
    }

    struct Bitmap: Equatable { let width: Int; let height: Int; let rgba: [UInt8] }

    /// Decodes the DOOM picture (patch) format into row-major RGBA.
    static func decodePicture(_ lump: Data, palette: [UInt8]) -> Bitmap? {
        guard palette.count == 256 * 4, lump.count >= 8 else { return nil }
        let base = lump.startIndex
        func u16(_ o: Int) -> Int { Int(lump[base + o..<base + o + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian) }
        func u32(_ o: Int) -> Int { Int(lump[base + o..<base + o + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian) }
        func u8(_ o: Int) -> UInt8? { (base + o) < lump.endIndex ? lump[base + o] : nil }

        let width = u16(0), height = u16(2)
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              lump.count >= 8 + width * 4 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)   // transparent by default

        for x in 0..<width {
            var o = u32(8 + x * 4)                                    // column data offset
            while true {
                guard let topdelta = u8(o) else { return nil }
                if topdelta == 0xFF { break }
                guard let length = u8(o + 1) else { return nil }
                let dataStart = o + 3                                 // skip topdelta,length,unused
                guard dataStart + Int(length) <= lump.count else { return nil }
                for r in 0..<Int(length) {
                    let y = Int(topdelta) + r
                    guard y < height else { continue }
                    let idx = Int(lump[base + dataStart + r]) * 4
                    let p = (y * width + x) * 4
                    rgba[p + 0] = palette[idx + 0]
                    rgba[p + 1] = palette[idx + 1]
                    rgba[p + 2] = palette[idx + 2]
                    rgba[p + 3] = 255
                }
                o = dataStart + Int(length) + 1                      // skip trailing unused byte
            }
        }
        return Bitmap(width: width, height: height, rgba: rgba)
    }
}
