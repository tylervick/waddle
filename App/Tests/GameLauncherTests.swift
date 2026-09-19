import SwiftData
import XCTest
@testable import Waddle

@MainActor
final class GameLauncherTests: XCTestCase {
    var service: LibraryService!
    var tmp: URL!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, Game.self, configurations: config)
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        service = LibraryService(context: ModelContext(container), store: WADStore(directory: tmp))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tmp) }

    func testBaseGameLaunchKeysSavesByGameIdStampsLastPlayedAndAppliesScheme() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        let game = try XCTUnwrap(try service.game(id: iwad.id))
        try service.setSchemeOverride(TouchControlScheme.modern.rawValue, for: game)
        let when = Date(timeIntervalSince1970: 999)
        let plan = try GameLauncher.prepare(game, library: service, at: when)
        XCTAssertEqual(Array(plan.arguments.prefix(3)), ["woof", "-iwad", service.fileURL(for: iwad).path])
        XCTAssertFalse(plan.arguments.contains("-file"))
        XCTAssertTrue(plan.arguments.contains(LibraryService.savesDirectory(forGameID: iwad.id).path),
                      "a base game's saves key is its IWAD's id")
        XCTAssertEqual(plan.scheme, .modern)
        XCTAssertEqual(try service.game(id: game.id)?.lastPlayed, when)
    }

    func testModdedGameLaunchLoadsItsFilesAndStampsLastPlayed() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        let pwad = try service.registerImported(filename: "sunlust.wad", sha1: "p", kind: WADKind.pwad.rawValue, family: "doom2", hasMaps: true)
        let game = try service.createGame(name: "Sun", baseID: iwad.id, fileIDs: [pwad.id])
        let when = Date(timeIntervalSince1970: 777)
        let plan = try GameLauncher.prepare(game, library: service, at: when)
        XCTAssertEqual(plan.arguments[1], "-iwad")
        let fileIdx = try XCTUnwrap(plan.arguments.firstIndex(of: "-file"))
        XCTAssertEqual(plan.arguments[fileIdx + 1], service.fileURL(for: pwad).path)
        XCTAssertTrue(plan.arguments.contains(LibraryService.savesDirectory(forGameID: game.id).path))
        XCTAssertEqual(try service.game(id: game.id)?.lastPlayed, when)
    }

    func testMissingFileThrowsItsIdAndDoesNotStampLastPlayed() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        let gone = UUID()
        let game = try service.createGame(name: "Broken", baseID: iwad.id, fileIDs: [gone])
        XCTAssertThrowsError(try GameLauncher.prepare(game, library: service)) {
            XCTAssertEqual($0 as? GameLaunchError, .missingWAD(gone))
        }
        XCTAssertNil(try service.game(id: game.id)?.lastPlayed)
    }

    // MARK: - Continue (#112)

    /// Writes real save files into `key`'s saves directory with the given
    /// modification dates, and arranges for the directory to be removed again --
    /// it lives under the app's Documents directory, shared by every test.
    private func writeSaves(_ files: [(String, TimeInterval)], forKey key: UUID) throws {
        let dir = LibraryService.savesDirectory(forGameID: key)
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
        let game = try XCTUnwrap(try service.game(id: iwad.id))
        try writeSaves([("woofsav0.dsg", 100), ("woofsav6.dsg", 300), ("woofsav2.dsg", 200)],
                       forKey: game.id)
        let plan = try GameLauncher.prepare(game, library: service,
                                               mode: .continueNewest)
        let idx = try XCTUnwrap(plan.arguments.firstIndex(of: "-loadgame"))
        XCTAssertEqual(plan.arguments[idx + 1], "6")
    }

    func testContinueResumesTheAutosaveWhenItIsNewest() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        let game = try XCTUnwrap(try service.game(id: iwad.id))
        try writeSaves([("woofsav1.dsg", 100), ("autosave.dsg", 400)], forKey: game.id)
        let plan = try GameLauncher.prepare(game, library: service,
                                               mode: .continueNewest)
        let idx = try XCTUnwrap(plan.arguments.firstIndex(of: "-loadgame"))
        XCTAssertEqual(plan.arguments[idx + 1], "255")
    }

    func testContinueWithNoSavesIsIdenticalToANewGame() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        let game = try XCTUnwrap(try service.game(id: iwad.id))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forGameID: game.id))
        }
        let continueArgs = try GameLauncher.prepare(game, library: service,
                                                       mode: .continueNewest).arguments
        let newGameArgs = try GameLauncher.prepare(game, library: service,
                                                      mode: .newGame).arguments
        XCTAssertFalse(continueArgs.contains("-loadgame"))
        XCTAssertEqual(continueArgs, newGameArgs)
        XCTAssertNil(GameLauncher.continuableSlot(for: game, library: service))
    }

    func testNewGameNeverLoadsASaveEvenWhenOneExists() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        let game = try XCTUnwrap(try service.game(id: iwad.id))
        try writeSaves([("woofsav3.dsg", 100)], forKey: game.id)
        let plan = try GameLauncher.prepare(game, library: service)
        XCTAssertFalse(plan.arguments.contains("-loadgame"))
        // ...but the UI is still told a Continue is available.
        XCTAssertEqual(GameLauncher.continuableSlot(for: game, library: service), 3)
    }

    func testGameContinueKeysSavesOffTheGame() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        let game = try service.createGame(name: "Sun", baseID: iwad.id, fileIDs: [])
        // A save under the *IWAD's* key must not leak into the game's Continue.
        try writeSaves([("woofsav9.dsg", 500)], forKey: iwad.id)
        try writeSaves([("woofsav4.dsg", 100)], forKey: game.id)
        let plan = try GameLauncher.prepare(game, library: service,
                                               mode: .continueNewest)
        let idx = try XCTUnwrap(plan.arguments.firstIndex(of: "-loadgame"))
        XCTAssertEqual(plan.arguments[idx + 1], "4")
    }

    func testGameWithMissingWADThrows() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        let game = try service.createGame(name: "Broken", baseID: iwad.id, fileIDs: [UUID()])
        XCTAssertThrowsError(try GameLauncher.prepare(game, library: service))
    }

    func testLaunchFailureCopyDistinguishesNoBaseFromMissingFile() {
        XCTAssertEqual(LaunchFailure.message(for: LaunchArgumentsError.missingBase),
                       "This game needs a base game. Choose one on its page.")
        XCTAssertEqual(LaunchFailure.message(for: GameLaunchError.missingWAD(UUID())),
                       "A file in this game is missing from the library.")
        XCTAssertEqual(LaunchFailure.message(for: LaunchArgumentsError.missingWAD(UUID())),
                       "A file in this game is missing from the library.")
    }
}
