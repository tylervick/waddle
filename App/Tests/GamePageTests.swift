import XCTest
@testable import Waddle

/// The game page's decisions (spec §3.2), pure so they can be tested without a
/// view harness — the same reason `Shelf` exists.
final class GamePageTests: XCTestCase {
    private func file(_ name: String, kind: WADKind, hasMaps: Bool = false) -> WADFile {
        WADFile(filename: name, displayName: (name as NSString).deletingPathExtension,
                kindRaw: kind.rawValue, sha1: name, gameFamilyRaw: GameFamily.doom2.rawValue,
                hasMaps: hasMaps)
    }

    // MARK: change-with-saves

    func testBaseAndFileEditsWarnOnlyWhenTheGameHasSaves() {
        XCTAssertTrue(GamePage.warnsBeforeApplying(.base(UUID()), saveCount: 1))
        XCTAssertTrue(GamePage.warnsBeforeApplying(.files([]), saveCount: 3))
        XCTAssertFalse(GamePage.warnsBeforeApplying(.base(nil), saveCount: 0))
        XCTAssertFalse(GamePage.warnsBeforeApplying(.files([UUID()]), saveCount: 0))
    }

    // MARK: naming

    func testDuplicateNameAppendsCopy() {
        XCTAssertEqual(GamePage.duplicateName(for: "Sunlust"), "Sunlust copy")
        XCTAssertEqual(GamePage.duplicateName(for: "Sunlust copy"), "Sunlust copy copy",
                       "no clever counters — the player renames if they care")
    }

    // MARK: row labels (spec §2.1 roles, §3.2 copy)

    func testRoleLabels() {
        XCTAssertEqual(GamePage.roleLabel(for: file("sunlust.wad", kind: .pwad, hasMaps: true)), "Map set")
        XCTAssertEqual(GamePage.roleLabel(for: file("smooth.wad", kind: .pwad)), "Add-on")
        XCTAssertEqual(GamePage.roleLabel(for: file("fix.deh", kind: .deh)), "Patch")
    }

    // MARK: the Add picker

    func testAddableFilesExcludeBasesAndFilesAlreadyInTheGame() {
        let base = file("doom2.wad", kind: .iwad)
        let inGame = file("sunlust.wad", kind: .pwad, hasMaps: true)
        let addOn = file("smooth.wad", kind: .pwad)
        let patch = file("fix.deh", kind: .deh)
        let game = Game(name: "Sunlust", baseID: base.id, fileIDs: [inGame.id])

        let addable = GamePage.addableFiles(from: [base, inGame, addOn, patch], to: game)

        XCTAssertEqual(addable.map(\.filename), ["smooth.wad", "fix.deh"])
    }

    // MARK: delete copy

    func testDeleteMessageNamesSavesAndUnsharedFiles() {
        XCTAssertEqual(GamePage.deleteMessage(gameName: "Sunlust", saveCount: 3, deletableFiles: ["sunlust.wad"]),
                       "Delete Sunlust and its 3 saves?\nsunlust.wad isn't used by any other game.")
        XCTAssertEqual(GamePage.deleteMessage(gameName: "Sunlust", saveCount: 1, deletableFiles: []),
                       "Delete Sunlust and its 1 save?")
        XCTAssertEqual(GamePage.deleteMessage(gameName: "Sunlust", saveCount: 0, deletableFiles: ["a.wad", "b.wad"]),
                       "Delete Sunlust?\na.wad and b.wad aren't used by any other game.")
        XCTAssertEqual(GamePage.deleteMessage(gameName: "Sunlust", saveCount: 0,
                                              deletableFiles: ["a.wad", "b.wad", "c.wad"]),
                       "Delete Sunlust?\na.wad, b.wad and c.wad aren't used by any other game.")
    }

    // MARK: Files screen copy

    func testUsedByLine() {
        XCTAssertEqual(GamePage.usedByLine(gameNames: []), "Not used by any game")
        XCTAssertEqual(GamePage.usedByLine(gameNames: ["Sunlust"]), "Used by Sunlust")
        XCTAssertEqual(GamePage.usedByLine(gameNames: ["DOOM II", "Sunlust"]), "Used by DOOM II, Sunlust")
    }
}
