import XCTest
@testable import WADdle

/// Covers the filename -> `-loadgame` mapping and the newest-save selection
/// Continue is built on. The literal filenames here are the engine's own
/// (`woofsav<n>.dsg`, `autosave.dsg`) -- see `EngineSaveSlot`'s doc comment for
/// the Woof sources each one is read out of.
@MainActor
final class EngineSaveSlotTests: XCTestCase {
    private func slot(_ id: String, _ epoch: TimeInterval) -> LibraryService.SaveSlot {
        LibraryService.SaveSlot(id: id, modified: Date(timeIntervalSince1970: epoch))
    }

    // MARK: Filename -> argument

    func testManualSlotFilenamesMapToTheirNumber() {
        XCTAssertEqual(EngineSaveSlot.loadGameArgument(forFilename: "woofsav0.dsg"), 0)
        XCTAssertEqual(EngineSaveSlot.loadGameArgument(forFilename: "woofsav7.dsg"), 7)
        XCTAssertEqual(EngineSaveSlot.loadGameArgument(forFilename: "woofsav12.dsg"), 12)
        // 77 is the last addressable name: page 7, slot 7.
        XCTAssertEqual(EngineSaveSlot.loadGameArgument(forFilename: "woofsav77.dsg"), 77)
    }

    func testAutosaveFilenameMapsToTheSentinel() {
        XCTAssertEqual(EngineSaveSlot.loadGameArgument(forFilename: "autosave.dsg"), 255)
        XCTAssertEqual(EngineSaveSlot.autoSaveArgument, 255)
    }

    func testFilenameMatchingIsCaseInsensitive() {
        // The engine lowercases what it writes but matches a pre-existing file
        // case-insensitively, so either casing can be on disk.
        XCTAssertEqual(EngineSaveSlot.loadGameArgument(forFilename: "WOOFSAV3.DSG"), 3)
        XCTAssertEqual(EngineSaveSlot.loadGameArgument(forFilename: "AutoSave.dsg"), 255)
    }

    func testNamesTheEngineCannotLoadBySlotMapToNil() {
        for name in ["woofsav78.dsg",   // past page 7 slot 7; -loadgame rejects it
                     "woofsav100.dsg",
                     "woofsav-1.dsg",
                     "woofsav07.dsg",   // %d never writes a leading zero
                     "woofsav.dsg",     // no number at all
                     "woofsav1.txt",
                     "woofsav1.dsg.bak",
                     "doomsav1.dsg",    // a different port's prefix
                     "MBFSAV1.dsg",     // G_MBFSaveGameName's legacy name
                     "autosave.txt",
                     "woof.cfg",
                     ""] {
            XCTAssertNil(EngineSaveSlot.loadGameArgument(forFilename: name),
                         "\(name) is not loadable by slot")
        }
    }

    // MARK: Newest-save selection

    func testNewestSaveWinsRegardlessOfInputOrder() {
        // Passed oldest-first on purpose: "newest" must come from `modified`,
        // not from the caller's ordering.
        let slots = [slot("woofsav0.dsg", 100),
                     slot("woofsav5.dsg", 300),
                     slot("woofsav2.dsg", 200)]
        XCTAssertEqual(EngineSaveSlot.newestLoadGameArgument(in: slots), 5)
        XCTAssertEqual(EngineSaveSlot.newestLoadGameArgument(in: slots.reversed()), 5)
    }

    func testAutosaveWinsWhenItIsTheNewest() {
        let slots = [slot("woofsav3.dsg", 100), slot("autosave.dsg", 200)]
        XCTAssertEqual(EngineSaveSlot.newestLoadGameArgument(in: slots), 255)
    }

    func testAutosaveLosesWhenAManualSaveIsNewer() {
        let slots = [slot("autosave.dsg", 100), slot("woofsav3.dsg", 200)]
        XCTAssertEqual(EngineSaveSlot.newestLoadGameArgument(in: slots), 3)
    }

    func testNoSavesYieldsNoSlot() {
        XCTAssertNil(EngineSaveSlot.newestLoadGameArgument(in: []))
    }

    func testNewerUnloadableFileFallsThroughToTheNewestLoadableOne() {
        // The engine drops other files in here (config, screenshots); a newer
        // one of those must not suppress Continue.
        let slots = [slot("woof.cfg", 900),
                     slot("woofsav4.dsg", 300),
                     slot("woofsav1.dsg", 200)]
        XCTAssertEqual(EngineSaveSlot.newestLoadGameArgument(in: slots), 4)
    }

    func testOnlyUnloadableFilesYieldNoSlot() {
        XCTAssertNil(EngineSaveSlot.newestLoadGameArgument(
            in: [slot("woof.cfg", 100), slot("woofsav78.dsg", 200)]))
    }
}
