import SwiftData
import XCTest
@testable import WADdle

@MainActor
final class PlayableLauncherTests: XCTestCase {
    var service: LibraryService!
    var tmp: URL!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, configurations: config)
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        service = LibraryService(context: ModelContext(container), store: WADStore(directory: tmp))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tmp) }

    func testBaseGameLaunchKeysSavesByWADIdStampsLastPlayedAndAppliesScheme() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        iwad.schemeOverrideRaw = TouchControlScheme.modern.rawValue
        try service.saveChanges()
        let when = Date(timeIntervalSince1970: 999)
        let plan = try PlayableLauncher.prepare(.baseGame(iwad), library: service, at: when)
        XCTAssertEqual(Array(plan.arguments.prefix(3)), ["woof", "-iwad", service.fileURL(for: iwad).path])
        XCTAssertFalse(plan.arguments.contains("-file"))
        // saves dir is keyed by the base game's own WADFile.id
        XCTAssertTrue(plan.arguments.contains(LibraryService.savesDirectory(forLoadoutID: iwad.id).path))
        XCTAssertEqual(plan.scheme, .modern)
        XCTAssertEqual(try service.wad(id: iwad.id)?.lastPlayed, when)
    }

    func testPresetLaunchUsesLoadoutPathStampsLoadoutLastPlayed() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        let pwad = try service.registerImported(filename: "sunlust.wad", sha1: "p", kind: WADKind.pwad.rawValue, family: "doom2")
        // give the files real bytes so fileURL(for:) paths exist for arg building
        let preset = try service.createLoadout(name: "Sun", iwadID: iwad.id, pwadIDs: [pwad.id], dehIDs: [])
        let when = Date(timeIntervalSince1970: 777)
        let plan = try PlayableLauncher.prepare(.preset(preset), library: service, at: when)
        XCTAssertEqual(plan.arguments[1], "-iwad")
        XCTAssertTrue(plan.arguments.contains("-file"))
        XCTAssertTrue(plan.arguments.contains(LibraryService.savesDirectory(forLoadoutID: preset.id).path))
        XCTAssertEqual(try service.allLoadouts().first(where: { $0.id == preset.id })?.lastPlayed, when)
    }

    func testPresetWithMissingWADThrows() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        let preset = try service.createLoadout(name: "Broken", iwadID: iwad.id, pwadIDs: [UUID()], dehIDs: [])
        XCTAssertThrowsError(try PlayableLauncher.prepare(.preset(preset), library: service))
    }
}
