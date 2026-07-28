import Foundation

enum WADLumpIndexError: Error, Equatable { case tooSmall, badMagic, corruptDirectory, unreadable }

/// Reads a WAD's directory to byte offsets (which `WADParser` discards) so a
/// specific lump can be located and read without loading the whole file.
struct WADLumpIndex {
    struct Entry: Equatable { let name: String; let offset: Int; let size: Int }
    let entries: [Entry]

    /// Parses from a Data holding at least the header + directory region.
    init(wad data: Data) throws {
        guard data.count >= 12 else { throw WADLumpIndexError.tooSmall }
        let base = data.startIndex
        let magic = String(decoding: data[base..<base+4], as: UTF8.self)
        guard magic == "IWAD" || magic == "PWAD" else { throw WADLumpIndexError.badMagic }
        let numLumps = Int(Self.i32(data, at: base + 4))
        let dirOffset = Int(Self.i32(data, at: base + 8))
        guard numLumps >= 0, dirOffset >= 0, dirOffset + numLumps * 16 <= data.count else {
            throw WADLumpIndexError.corruptDirectory
        }
        var entries: [Entry] = []; entries.reserveCapacity(numLumps)
        for i in 0..<numLumps {
            let e = base + dirOffset + i * 16
            let offset = Int(Self.i32(data, at: e))
            let size = Int(Self.i32(data, at: e + 4))
            // A corrupt WAD can store negative filepos/size; skip them so they
            // never reach `UInt64(offset)` (which traps) or a negative read
            // count in `lumpData`.
            guard offset >= 0, size >= 0 else { continue }
            let nameBytes = data[(e + 8)..<(e + 16)].prefix { $0 != 0 }
            entries.append(Entry(name: String(decoding: nameBytes, as: UTF8.self).uppercased(),
                                 offset: offset, size: size))
        }
        self.entries = entries
    }

    /// First lump matching `name` (case-insensitive).
    func offsetSize(of name: String) -> (offset: Int, size: Int)? {
        let upper = name.uppercased()
        guard let e = entries.first(where: { $0.name == upper }) else { return nil }
        return (e.offset, e.size)
    }

    private static func i32(_ data: Data, at offset: Int) -> Int32 {
        data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian
    }

    /// Reads only the header + directory region via FileHandle (no full-file load).
    static func read(from url: URL) throws -> WADLumpIndex {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw WADLumpIndexError.unreadable }
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 12), header.count == 12 else {
            throw WADLumpIndexError.tooSmall
        }
        let magic = String(decoding: header[0..<4], as: UTF8.self)
        guard magic == "IWAD" || magic == "PWAD" else { throw WADLumpIndexError.badMagic }
        let numLumps = Int(i32(header, at: 0 + 4))
        let dirOffset = Int(i32(header, at: 0 + 8))
        guard numLumps >= 0, dirOffset >= 0 else { throw WADLumpIndexError.corruptDirectory }
        try handle.seek(toOffset: UInt64(dirOffset))
        let dir = (try handle.read(upToCount: numLumps * 16)) ?? Data()
        guard dir.count == numLumps * 16 else { throw WADLumpIndexError.corruptDirectory }
        // Re-parse from a synthetic buffer: reuse the Data initializer by
        // fabricating a minimal header pointing at the directory we just read.
        var buf = Data(magic.utf8)
        buf.append(withUnsafeBytes(of: Int32(numLumps).littleEndian) { Data($0) })
        buf.append(withUnsafeBytes(of: Int32(12).littleEndian) { Data($0) })  // dir now at offset 12
        buf.append(dir)
        return try WADLumpIndex(wad: buf)   // offsets inside `dir` still point into the real file
    }

    /// Reads a single lump's bytes from the file at its recorded offset/size.
    static func lumpData(_ name: String, at url: URL, index: WADLumpIndex) throws -> Data? {
        guard let (offset, size) = index.offsetSize(of: name) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw WADLumpIndexError.unreadable }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: size)
    }
}
