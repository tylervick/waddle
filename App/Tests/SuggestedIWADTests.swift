import SwiftData
import XCTest
@testable import WADdle

@MainActor
final class SuggestedIWADTests: XCTestCase {
    var service: LibraryService!
    var tmp: URL!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, configurations: config)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        service = LibraryService(context: ModelContext(container),
                                 store: WADStore(directory: tmp))
        try service.seedBundledContentIfNeeded()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testDoom2FamilyPrefersRealIWADOverFreedoom() throws {
        let doom2 = try service.registerImported(filename: "doom2.wad", sha1: "d2",
                                                 kind: "IWAD", family: "doom2")
        let pwad = try service.registerImported(filename: "sunlust.wad", sha1: "s",
                                                kind: "PWAD", family: "doom2")
        XCTAssertEqual(try service.suggestedIWAD(for: pwad)?.id, doom2.id)
    }

    func testFallsBackToBundledFreedoomByFamily() throws {
        let e1 = try service.registerImported(filename: "ep.wad", sha1: "e",
                                              kind: "PWAD", family: "doom1")
        XCTAssertEqual(try service.suggestedIWAD(for: e1)?.filename, "freedoom1.wad")
        let m1 = try service.registerImported(filename: "maps.wad", sha1: "m",
                                              kind: "PWAD", family: "doom2")
        XCTAssertEqual(try service.suggestedIWAD(for: m1)?.filename, "freedoom2.wad")
        let unk = try service.registerImported(filename: "res.wad", sha1: "u",
                                               kind: "PWAD", family: "unknown")
        XCTAssertEqual(try service.suggestedIWAD(for: unk)?.filename, "freedoom2.wad")
    }
}
