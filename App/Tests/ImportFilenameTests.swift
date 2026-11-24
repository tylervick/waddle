import SwiftData
import XCTest
import ZIPFoundation
@testable import Waddle

/// `ImportFilename`, the one place an incoming name is made safe, and the
/// `.pk3` refusal, on routes other than a link (#500 review).
@MainActor
final class ImportFilenameTests: XCTestCase {
    func testControlAndFormatCharactersAreDropped() {
        XCTAssertEqual(ImportFilename.sanitized("ma\np\u{07}.wad"), "map.wad")
        XCTAssertEqual(ImportFilename.sanitized("evil\u{202E}daw.zip"), "evildaw.zip",
                       "a right-to-left override would display the name reversed")
        XCTAssertEqual(ImportFilename.sanitized("a\tb\r.wad"), "ab.wad")
    }

    func testSeparatorsBecomeUnderscores() {
        XCTAssertEqual(ImportFilename.sanitized("../../etc/map.wad"), "_.._etc_map.wad")
        XCTAssertEqual(ImportFilename.sanitized(#"dir\map:1.wad"#), "dir_map_1.wad")
    }

    func testLeadingDotsAndReservedNamesGo() {
        XCTAssertEqual(ImportFilename.sanitized(".hidden.wad"), "hidden.wad")
        XCTAssertEqual(ImportFilename.sanitized(".."), "download")
        XCTAssertEqual(ImportFilename.sanitized("."), "download")
        XCTAssertEqual(ImportFilename.sanitized(""), "download")
        XCTAssertEqual(ImportFilename.sanitized("  \n "), "download")
        XCTAssertEqual(ImportFilename.sanitized("CON.wad"), "download.wad")
        XCTAssertEqual(ImportFilename.sanitized("lpt1"), "download")
        XCTAssertEqual(ImportFilename.sanitized("console.wad"), "console.wad")
    }

    func testOrdinaryNamesAreUnchanged() {
        for name in ["sunlust.wad", "Eviternity II RC5.wad", "tweaks.bex", "Ancient Aliens (1).zip", "café.wad", "地图.wad"] {
            XCTAssertEqual(ImportFilename.sanitized(name), name)
        }
    }

    func testAnOverlongNameIsShortenedOnACharacterBoundaryKeepingItsExtension() {
        let long = String(repeating: "é", count: 200) + ".wad"   // 404 bytes
        let short = ImportFilename.sanitized(long)
        XCTAssertLessThanOrEqual(short.utf8.count, ImportFilename.maxBytes)
        XCTAssertTrue(short.hasSuffix(".wad"))
        XCTAssertEqual(short.dropLast(4).allSatisfy { $0 == "é" }, true)
        XCTAssertEqual(ImportFilename.sanitized(short), short, "sanitising is idempotent")
    }

    // MARK: Through the importer, on a route that is not a link

    private var tmp: URL!
    private var library: LibraryService!
    private var importer: ImportService!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Game.self, configurations: config)
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = WADStore(directory: tmp.appendingPathComponent("WADs", isDirectory: true))
        library = LibraryService(context: ModelContext(container), store: store)
        importer = ImportService(library: library, store: store, notices: ImportNotices(),
                                 usage: UsageStore(directory: tmp.appendingPathComponent("Diagnostics", isDirectory: true)))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testASuggestedNameIsSanitisedOnEveryRoute() async throws {
        let url = tmp.appendingPathComponent("download")
        try makeWAD(magic: "PWAD", lumps: ["MAP01"]).write(to: url)
        let outcome = await importer.importFile(at: url, from: .openIn, suggestedFilename: "ma\np\u{07}.wad")
        XCTAssertEqual(outcome.imported, ["map"])
        XCTAssertEqual(try library.allWADs().first?.filename, "map.wad")
    }

    func testAPK3IsRefusedNotUnpacked() async throws {
        let url = tmp.appendingPathComponent("mod.pk3")
        let archive = try Archive(url: url, accessMode: .create)
        let wadData = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        try archive.addEntry(with: "maps/MAP01.wad", type: .file, uncompressedSize: Int64(wadData.count),
                             provider: { pos, size in wadData.subdata(in: Int(pos)..<Int(pos) + size) })

        let outcome = await importer.importFile(at: url, from: .openIn)

        XCTAssertEqual(outcome.rejected, ["mod.pk3": ImportFileType.refusedReason])
        XCTAssertTrue(outcome.imported.isEmpty)
        XCTAssertTrue(try library.allWADs().isEmpty)
        XCTAssertNil(ImportFileType.resolve(url: url, name: "mod.pk3"), "a .pk3 is never sniffed as a zip")
    }
}
