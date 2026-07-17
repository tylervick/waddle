import Foundation

enum WADKind: String {
    case iwad = "IWAD"
    case pwad = "PWAD"
}

enum MapFormat { case episodic, mapXX, none }

enum GameFamily: String { case doom1, doom2, unknown }

struct ParsedWAD {
    let kind: WADKind
    let lumpNames: [String]
}

enum WADParseError: Error, Equatable {
    case tooSmall
    case badMagic
    case corruptDirectory
}

enum WADParser {
    /// WAD layout: magic(4) | numLumps(i32le) | dirOffset(i32le), then
    /// directory entries of filepos(4) | size(4) | name(8, NUL-padded).
    static func parse(_ data: Data) throws -> ParsedWAD {
        guard data.count >= 12 else { throw WADParseError.tooSmall }
        let base = data.startIndex
        guard let kind = WADKind(rawValue: String(decoding: data[base..<base+4], as: UTF8.self))
        else { throw WADParseError.badMagic }

        let numLumps = Int(readInt32LE(data, at: base+4))
        let dirOffset = Int(readInt32LE(data, at: base+8))
        guard numLumps >= 0, dirOffset >= 0,
              dirOffset + numLumps * 16 <= data.count
        else { throw WADParseError.corruptDirectory }

        var names: [String] = []
        names.reserveCapacity(numLumps)
        for i in 0..<numLumps {
            let entry = dirOffset + i * 16
            let nameBytes = data[(base + entry + 8)..<(base + entry + 16)].prefix { $0 != 0 }
            names.append(String(decoding: nameBytes, as: UTF8.self).uppercased())
        }
        return ParsedWAD(kind: kind, lumpNames: names)
    }

    static func mapFormat(of lumpNames: [String]) -> MapFormat {
        if lumpNames.contains(where: isMapXX) { return .mapXX }
        if lumpNames.contains(where: isEpisodic) { return .episodic }
        return .none
    }

    static func gameFamily(of lumpNames: [String]) -> GameFamily {
        switch mapFormat(of: lumpNames) {
        case .mapXX: .doom2
        case .episodic: .doom1
        case .none: .unknown
        }
    }

    private static func readInt32LE(_ data: Data, at offset: Int) -> Int32 {
        data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian
    }

    private static func isEpisodic(_ name: String) -> Bool {
        name.count == 4 && name.first == "E" && name[name.index(name.startIndex, offsetBy: 2)] == "M"
            && name.dropFirst().first.map { ("0"..."9").contains($0) } ?? false
            && name.last.map { ("0"..."9").contains($0) } ?? false
    }

    private static func isMapXX(_ name: String) -> Bool {
        name.count == 5 && name.hasPrefix("MAP") && name.dropFirst(3).allSatisfy { ("0"..."9").contains($0) }
    }
}
