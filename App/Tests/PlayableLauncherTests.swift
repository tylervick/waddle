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

    // MARK: - Continue (#112)

    /// Writes real save files into `key`'s saves directory with the given
    /// modification dates, and arranges for the directory to be removed again --
    /// it lives under the app's Documents directory, shared by every test.
    private func writeSaves(_ files: [(String, TimeInterval)], forKey key: UUID) throws {
        let dir = LibraryService.savesDirectory(forLoadoutID: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for (name, epoch) in files {
            let url = dir.appendingPathComponent(name)
            try Data().write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: epoch)], ofItemAtPath: url.path)
        }
    }

    func testContinueLaunchesIntoTheNewestSave() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        try writeSaves([("woofsav0.dsg", 100), ("woofsav6.dsg", 300), ("woofsav2.dsg", 200)],
                       forKey: iwad.id)
        let plan = try PlayableLauncher.prepare(.baseGame(iwad), library: service,
                                               mode: .continueNewest)
        let idx = try XCTUnwrap(plan.arguments.firstIndex(of: "-loadgame"))
        XCTAssertEqual(plan.arguments[idx + 1], "6")
    }

    func testContinueResumesTheAutosaveWhenItIsNewest() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        try writeSaves([("woofsav1.dsg", 100), ("autosave.dsg", 400)], forKey: iwad.id)
        let plan = try PlayableLauncher.prepare(.baseGame(iwad), library: service,
                                               mode: .continueNewest)
        let idx = try XCTUnwrap(plan.arguments.firstIndex(of: "-loadgame"))
        XCTAssertEqual(plan.arguments[idx + 1], "255")
    }

    func testContinueWithNoSavesIsIdenticalToANewGame() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forLoadoutID: iwad.id))
        }
        let continueArgs = try PlayableLauncher.prepare(.baseGame(iwad), library: service,
                                                       mode: .continueNewest).arguments
        let newGameArgs = try PlayableLauncher.prepare(.baseGame(iwad), library: service,
                                                      mode: .newGame).arguments
        XCTAssertFalse(continueArgs.contains("-loadgame"))
        XCTAssertEqual(continueArgs, newGameArgs)
        XCTAssertNil(PlayableLauncher.continuableSlot(for: .baseGame(iwad), library: service))
    }

    func testNewGameNeverLoadsASaveEvenWhenOneExists() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        try writeSaves([("woofsav3.dsg", 100)], forKey: iwad.id)
        let plan = try PlayableLauncher.prepare(.baseGame(iwad), library: service)
        XCTAssertFalse(plan.arguments.contains("-loadgame"))
        // ...but the UI is still told a Continue is available.
        XCTAssertEqual(PlayableLauncher.continuableSlot(for: .baseGame(iwad), library: service), 3)
    }

    func testPresetContinueKeysSavesOffTheLoadout() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        let preset = try service.createLoadout(name: "Sun", iwadID: iwad.id, pwadIDs: [], dehIDs: [])
        // A save under the *IWAD's* key must not leak into the preset's Continue.
        try writeSaves([("woofsav9.dsg", 500)], forKey: iwad.id)
        try writeSaves([("woofsav4.dsg", 100)], forKey: preset.id)
        let plan = try PlayableLauncher.prepare(.preset(preset), library: service,
                                               mode: .continueNewest)
        let idx = try XCTUnwrap(plan.arguments.firstIndex(of: "-loadgame"))
        XCTAssertEqual(plan.arguments[idx + 1], "4")
    }

    func testPresetWithMissingWADThrows() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        let preset = try service.createLoadout(name: "Broken", iwadID: iwad.id, pwadIDs: [UUID()], dehIDs: [])
        XCTAssertThrowsError(try PlayableLauncher.prepare(.preset(preset), library: service))
    }
}
