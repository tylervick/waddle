import XCTest
@testable import WADdle

final class LoadoutArgumentsTests: XCTestCase {
    private func resolver(_ map: [UUID: String]) -> (UUID) throws -> URL {
        { id in
            guard let path = map[id] else { throw LoadoutArgumentsError.missingWAD(id) }
            return URL(fileURLWithPath: path)
        }
    }

    func testIWADOnly() throws {
        let loadout = Loadout(name: "F1", iwadID: UUID())
        let args = try LoadoutArguments.build(
            loadout: loadout, resolve: resolver([loadout.iwadID: "/gd/freedoom1.wad"]))
        let loadoutID = loadout.id
        addTeardownBlock { try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forLoadoutID: loadoutID)) }
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
        let args = try LoadoutArguments.build(loadout: loadout, resolve: resolver([
            iwad: "/gd/freedoom2.wad",
            a: "/wads/a.wad",
            b: "/wads/Eviternity II.wad",
            deh: "/wads/fix.deh",
        ]))
        let loadoutID = loadout.id
        addTeardownBlock { try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forLoadoutID: loadoutID)) }
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
        XCTAssertThrowsError(try LoadoutArguments.build(loadout: loadout,
                                                        resolve: resolver([:]))) {
            XCTAssertEqual($0 as? LoadoutArgumentsError, .missingWAD(loadout.iwadID))
        }
    }

    func testSavesDirectoryIsCreated() throws {
        let loadout = Loadout(name: "F1", iwadID: UUID())
        _ = try LoadoutArguments.build(
            loadout: loadout, resolve: resolver([loadout.iwadID: "/gd/f1.wad"]))
        let saves = LibraryService.savesDirectory(forLoadoutID: loadout.id)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: saves.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        try? FileManager.default.removeItem(at: saves)
    }

    func testBuildBaseGameOnlyArgv() throws {
        let saveID = UUID()
        let args = try LoadoutArguments.build(
            iwadURL: URL(fileURLWithPath: "/tmp/doom2.wad"), saveID: saveID)
        addTeardownBlock { try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forLoadoutID: saveID)) }
        XCTAssertEqual(Array(args.prefix(3)), ["woof", "-iwad", "/tmp/doom2.wad"])
        XCTAssertFalse(args.contains("-file"))
        XCTAssertFalse(args.contains("-deh"))
        XCTAssertFalse(args.contains("-complevel"))
        XCTAssertTrue(args.contains("-save"))
    }

    func testBuildWithPWADsAndComplevel() throws {
        let saveID = UUID()
        let args = try LoadoutArguments.build(
            iwadURL: URL(fileURLWithPath: "/tmp/doom2.wad"), saveID: saveID,
            pwadURLs: [URL(fileURLWithPath: "/tmp/sunlust.wad")], complevel: "mbf21")
        addTeardownBlock { try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forLoadoutID: saveID)) }
        XCTAssertEqual(args[args.firstIndex(of: "-file")! + 1], "/tmp/sunlust.wad")
        XCTAssertEqual(args[args.firstIndex(of: "-complevel")! + 1], "mbf21")
    }
}
