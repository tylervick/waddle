import XCTest
@testable import Waddle

final class LaunchArgumentsTests: XCTestCase {
    private func resolver(_ map: [UUID: String]) -> (UUID) throws -> URL {
        { id in
            guard let path = map[id] else { throw LaunchArgumentsError.missingWAD(id) }
            return URL(fileURLWithPath: path)
        }
    }

    func testIWADOnly() throws {
        let loadout = Loadout(name: "F1", iwadID: UUID())
        let args = try LaunchArguments.build(
            loadout: loadout, resolve: resolver([loadout.iwadID: "/gd/freedoom1.wad"]))
        let loadoutID = loadout.id
        addTeardownBlock { try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forGameID: loadoutID)) }
        XCTAssertEqual(Array(args.prefix(3)), ["woof", "-iwad", "/gd/freedoom1.wad"])
        XCTAssertEqual(args[3], "-save")
        XCTAssertTrue(args[4].hasSuffix("/Saves/\(loadout.id.uuidString)"))
        XCTAssertFalse(args.contains("-file"))
        XCTAssertFalse(args.contains("-complevel"))
    }

    func testFullStackKeepsPWADOrderAndSpaces() throws {
        let iwad = UUID(), a = UUID(), b = UUID(), deh = UUID()
        let loadout = Loadout(name: "EvII", iwadID: iwad, pwadIDs: [b, a], dehIDs: [deh])
        loadout.complevel = "mbf21"
        let args = try LaunchArguments.build(loadout: loadout, resolve: resolver([
            iwad: "/gd/freedoom2.wad",
            a: "/wads/a.wad",
            b: "/wads/Eviternity II.wad",
            deh: "/wads/fix.deh",
        ]))
        let loadoutID = loadout.id
        addTeardownBlock { try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forGameID: loadoutID)) }
        let fileIdx = args.firstIndex(of: "-file")!
        XCTAssertEqual(args[fileIdx + 1], "/wads/Eviternity II.wad") // order preserved, space intact
        XCTAssertEqual(args[fileIdx + 2], "/wads/a.wad")
        let dehIdx = args.firstIndex(of: "-deh")!
        XCTAssertEqual(args[dehIdx + 1], "/wads/fix.deh")
        XCTAssertEqual(args.last!, "mbf21")
        XCTAssertEqual(args[args.count - 2], "-complevel")
    }

    func testMissingWADThrows() {
        let loadout = Loadout(name: "broken", iwadID: UUID())
        XCTAssertThrowsError(try LaunchArguments.build(loadout: loadout,
                                                        resolve: resolver([:]))) {
            XCTAssertEqual($0 as? LaunchArgumentsError, .missingWAD(loadout.iwadID))
        }
    }

    func testSavesDirectoryIsCreated() throws {
        let loadout = Loadout(name: "F1", iwadID: UUID())
        _ = try LaunchArguments.build(
            loadout: loadout, resolve: resolver([loadout.iwadID: "/gd/f1.wad"]))
        let saves = LibraryService.savesDirectory(forGameID: loadout.id)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: saves.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        try? FileManager.default.removeItem(at: saves)
    }

    func testBuildBaseGameOnlyArgv() throws {
        let saveID = UUID()
        let args = try LaunchArguments.build(
            iwadURL: URL(fileURLWithPath: "/tmp/doom2.wad"), saveID: saveID)
        addTeardownBlock { try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forGameID: saveID)) }
        XCTAssertEqual(Array(args.prefix(3)), ["woof", "-iwad", "/tmp/doom2.wad"])
        XCTAssertFalse(args.contains("-file"))
        XCTAssertFalse(args.contains("-deh"))
        XCTAssertFalse(args.contains("-complevel"))
        XCTAssertTrue(args.contains("-save"))
    }

    func testLoadGameSlotAppendsTheArgumentPair() throws {
        let saveID = UUID()
        let args = try LaunchArguments.build(
            iwadURL: URL(fileURLWithPath: "/tmp/doom2.wad"), saveID: saveID,
            loadGameSlot: 12)
        addTeardownBlock { try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forGameID: saveID)) }
        let idx = try XCTUnwrap(args.firstIndex(of: "-loadgame"))
        XCTAssertEqual(args[idx + 1], "12")
    }

    func testOmittedLoadGameSlotLeavesArgvUnchanged() throws {
        let saveID = UUID()
        let args = try LaunchArguments.build(
            iwadURL: URL(fileURLWithPath: "/tmp/doom2.wad"), saveID: saveID)
        addTeardownBlock { try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forGameID: saveID)) }
        XCTAssertFalse(args.contains("-loadgame"))
    }

    func testLoadoutOverloadForwardsTheLoadGameSlot() throws {
        let loadout = Loadout(name: "F1", iwadID: UUID())
        loadout.complevel = "mbf21"
        let args = try LaunchArguments.build(
            loadout: loadout, resolve: resolver([loadout.iwadID: "/gd/freedoom1.wad"]),
            loadGameSlot: EngineSaveSlot.autoSaveArgument)
        let loadoutID = loadout.id
        addTeardownBlock { try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forGameID: loadoutID)) }
        let idx = try XCTUnwrap(args.firstIndex(of: "-loadgame"))
        XCTAssertEqual(args[idx + 1], "255")
        // -complevel still trails it, as the pre-Continue argv order had it.
        XCTAssertEqual(Array(args.suffix(2)), ["-complevel", "mbf21"])
    }

    func testBuildWithPWADsAndComplevel() throws {
        let saveID = UUID()
        let args = try LaunchArguments.build(
            iwadURL: URL(fileURLWithPath: "/tmp/doom2.wad"), saveID: saveID,
            pwadURLs: [URL(fileURLWithPath: "/tmp/sunlust.wad")], complevel: "mbf21")
        addTeardownBlock { try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forGameID: saveID)) }
        XCTAssertEqual(args[args.firstIndex(of: "-file")! + 1], "/tmp/sunlust.wad")
        XCTAssertEqual(args[args.firstIndex(of: "-complevel")! + 1], "mbf21")
    }

    // MARK: - Game overload (spec §2.2: one ordered fileIDs list, roles from the file)

    private func gameResolver(_ map: [UUID: (String, WADKind)]) -> (UUID) throws -> ResolvedFile {
        { id in
            guard let (path, kind) = map[id] else { throw LaunchArgumentsError.missingWAD(id) }
            return ResolvedFile(url: URL(fileURLWithPath: path), kind: kind)
        }
    }

    func testGameSplitsOneOrderedListIntoFileAndDehGroupsKeepingOrder() throws {
        let iwad = UUID(), a = UUID(), b = UUID(), deh = UUID()
        // deh sits *between* the two PWADs on purpose: the split must be by
        // role, and each group must keep the list's relative order.
        let game = Game(name: "EvII", baseID: iwad, fileIDs: [b, deh, a], complevel: "mbf21")
        let args = try LaunchArguments.build(game: game, resolve: gameResolver([
            iwad: ("/gd/freedoom2.wad", .iwad),
            a: ("/wads/a.wad", .pwad),
            b: ("/wads/Eviternity II.wad", .pwad),
            deh: ("/wads/fix.deh", .deh),
        ]))
        let gameID = game.id
        addTeardownBlock { try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forGameID: gameID)) }
        XCTAssertEqual(Array(args.prefix(3)), ["woof", "-iwad", "/gd/freedoom2.wad"])
        let fileIdx = try XCTUnwrap(args.firstIndex(of: "-file"))
        XCTAssertEqual(args[fileIdx + 1], "/wads/Eviternity II.wad")
        XCTAssertEqual(args[fileIdx + 2], "/wads/a.wad")
        XCTAssertEqual(args[fileIdx + 3], "-deh")
        XCTAssertEqual(args[fileIdx + 4], "/wads/fix.deh")
        XCTAssertEqual(args.suffix(2), ["-complevel", "mbf21"])
    }

    func testGameSavesAreKeyedByTheGameId() throws {
        let iwad = UUID()
        let game = Game(name: "F1", baseID: iwad)
        let args = try LaunchArguments.build(game: game, resolve: gameResolver([iwad: ("/gd/f1.wad", .iwad)]))
        let gameID = game.id
        addTeardownBlock { try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forGameID: gameID)) }
        let saveIdx = try XCTUnwrap(args.firstIndex(of: "-save"))
        XCTAssertTrue(args[saveIdx + 1].hasSuffix("/Saves/\(game.id.uuidString)"))
        XCTAssertFalse(args.contains("-file"))
        XCTAssertFalse(args.contains("-deh"))
    }

    func testUnpairedGameThrowsMissingBase() {
        let game = Game(name: "orphan", baseID: nil)
        XCTAssertThrowsError(try LaunchArguments.build(game: game, resolve: gameResolver([:]))) {
            XCTAssertEqual($0 as? LaunchArgumentsError, .missingBase)
        }
    }

    func testGameWithAMissingFileThrowsThatFilesId() {
        let iwad = UUID(), gone = UUID()
        let game = Game(name: "broken", baseID: iwad, fileIDs: [gone])
        XCTAssertThrowsError(try LaunchArguments.build(game: game,
                                                       resolve: gameResolver([iwad: ("/gd/f1.wad", .iwad)]))) {
            XCTAssertEqual($0 as? LaunchArgumentsError, .missingWAD(gone))
        }
    }

    func testGameOverloadForwardsTheLoadGameSlot() throws {
        let iwad = UUID()
        let game = Game(name: "F1", baseID: iwad)
        let args = try LaunchArguments.build(game: game, resolve: gameResolver([iwad: ("/gd/f1.wad", .iwad)]),
                                             loadGameSlot: 6)
        let gameID = game.id
        addTeardownBlock { try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forGameID: gameID)) }
        let idx = try XCTUnwrap(args.firstIndex(of: "-loadgame"))
        XCTAssertEqual(args[idx + 1], "6")
    }
}
