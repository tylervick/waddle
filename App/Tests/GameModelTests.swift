import XCTest
@testable import Waddle

/// Spec §2.1 (roles are derived from the file, never stored) and the base-game
/// id invariant this plan leans on everywhere: a base game's `Game.id` is its
/// IWAD's `WADFile.id`, so its saves directory is the one the IWAD row already
/// used before `Game` existed.
final class GameModelTests: XCTestCase {
    private func file(kind: WADKind, hasMaps: Bool) -> WADFile {
        WADFile(filename: "x", displayName: "x", kindRaw: kind.rawValue, sha1: "s",
                gameFamilyRaw: GameFamily.unknown.rawValue, hasMaps: hasMaps)
    }

    func testIWADIsABaseWhateverItsMapsFlagSays() {
        XCTAssertEqual(file(kind: .iwad, hasMaps: true).role, .base)
        XCTAssertEqual(file(kind: .iwad, hasMaps: false).role, .base)
    }

    func testPWADWithMapsIsAMapSet() {
        XCTAssertEqual(file(kind: .pwad, hasMaps: true).role, .mapSet)
    }

    func testPWADWithoutMapsIsAnAddOn() {
        XCTAssertEqual(file(kind: .pwad, hasMaps: false).role, .addOn)
    }

    func testPatchIsAnAddOn() {
        XCTAssertEqual(file(kind: .deh, hasMaps: false).role, .addOn)
    }

    func testHasMapsDefaultsToFalseForExistingRows() {
        // The lightweight schema migration fills the new column with its
        // default; `migrateToGames` then re-parses present files. A row that
        // cannot be re-parsed must land on the conservative answer.
        let wad = WADFile(filename: "x", displayName: "x", kindRaw: WADKind.pwad.rawValue,
                          sha1: "s", gameFamilyRaw: GameFamily.unknown.rawValue)
        XCTAssertFalse(wad.hasMaps)
    }

    func testBaseGameSharesItsIWADsIdAndName() {
        let iwad = WADFile(filename: "doom2.wad", displayName: "DOOM II: Hell on Earth",
                           kindRaw: WADKind.iwad.rawValue, sha1: "s",
                           gameFamilyRaw: GameFamily.doom2.rawValue)
        let game = Game.baseGame(for: iwad)
        XCTAssertEqual(game.id, iwad.id, "the saves key must not change when a row becomes a game")
        XCTAssertEqual(game.baseID, iwad.id)
        XCTAssertEqual(game.name, "DOOM II: Hell on Earth")
        XCTAssertTrue(game.isBaseGame)
        XCTAssertTrue(game.fileIDs.isEmpty)
        XCTAssertFalse(game.isHidden)
        XCTAssertNil(game.lastPlayed)
    }
}
