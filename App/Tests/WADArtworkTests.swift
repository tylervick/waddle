import CoreGraphics
import ImageIO
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Waddle

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

    @MainActor
    func testCandidatesForBaseGameUseIWADItself() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, configurations: config)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let service = LibraryService(context: ModelContext(container), store: WADStore(directory: tmp))
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "iwadsha",
                                                kind: WADKind.iwad.rawValue, family: "doom2")
        let c = WADArtwork.candidates(for: .baseGame(iwad), library: service)
        XCTAssertEqual(c?.urls, [service.fileURL(for: iwad)])
        XCTAssertEqual(c?.cacheKey, "iwadsha")
    }

    // Two presets sharing a first PWAD with no TITLEPIC of its own (so art
    // falls back to the IWAD) must not collide on one cache entry when their
    // IWADs differ -- the cache key needs both SHA1s, not just the PWAD's.
    @MainActor
    func testCandidatesForPresetUsesCompositeCacheKey() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, configurations: config)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let service = LibraryService(context: ModelContext(container), store: WADStore(directory: tmp))
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "iw",
                                                kind: WADKind.iwad.rawValue, family: "doom2")
        let pwad = try service.registerImported(filename: "sunlust.wad", sha1: "pw",
                                                kind: WADKind.pwad.rawValue, family: "doom2")
        let loadout = try service.createLoadout(name: "Sunlust", iwadID: iwad.id,
                                                pwadIDs: [pwad.id], dehIDs: [])
        let c = WADArtwork.candidates(for: .preset(loadout), library: service)
        XCTAssertEqual(c?.urls, [service.fileURL(for: pwad), service.fileURL(for: iwad)])
        XCTAssertEqual(c?.cacheKey, "pw-iw")
    }

    func testDecodesSyntheticPNGTitlepic() async throws {
        // 1x1 CGImage, encoded to PNG bytes, used as a synthetic TITLEPIC
        // lump -- exercises the PNG-signature decode branch (as opposed to
        // the DOOM picture-format branch covered above).
        let context = CGContext(
            data: nil,
            width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let cgImage = context.makeImage()!

        let pngData = NSMutableData()
        let destination = CGImageDestinationCreateWithData(pngData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let wad = makeWAD([("TITLEPIC", Array(pngData as Data))])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wad")
        try wad.write(to: url); defer { try? FileManager.default.removeItem(at: url) }

        let key = "titleart-png-test-\(UUID().uuidString)"
        let img = await WADArtwork.titleImage(candidates: [url], cacheKey: key)
        XCTAssertNotNil(img)
        XCTAssertEqual(img?.width, 1)
        WADArtwork.clearCache(key: key)
    }
}
