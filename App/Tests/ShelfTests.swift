import SwiftData
import XCTest
@testable import Waddle

/// Covers the shelf's composition rules (spec §§2, 7): what the grid contains
/// and in what order, when the Continue hero appears, and what a tap resolves
/// to. `ShelfView` reads `LibraryService.shelfItems()` and then calls nothing
/// but `Shelf.ordered` / `Shelf.hero` / `Shelf.tapAction`, so these are the
/// screen's decisions rather than a helper it could bypass.
@MainActor
final class ShelfTests: XCTestCase {
    var service: LibraryService!
    var tmp: URL!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, configurations: config)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        service = LibraryService(context: ModelContext(container), store: WADStore(directory: tmp))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Ordering

    func testShelfOrdersRecentlyPlayedFirstThenAlphabetically() throws {
        let zulu = try service.registerImported(filename: "zulu.wad", sha1: "z",
                                                kind: WADKind.iwad.rawValue, family: "doom")
        let alpha = try service.registerImported(filename: "alpha.wad", sha1: "a",
                                                 kind: WADKind.iwad.rawValue, family: "doom")
        let mid = try service.registerImported(filename: "mid.wad", sha1: "m",
                                               kind: WADKind.iwad.rawValue, family: "doom")
        // Two played, out of alphabetical order relative to each other, so a
        // comparator that fell back to titles could not produce this sequence:
        // `zulu` is played most recently and must lead, `mid` follows, and only
        // the never-played `alpha` sorts by name — last, despite being first
        // alphabetically overall.
        try service.markPlayed(mid, at: Date(timeIntervalSince1970: 100))
        try service.markPlayed(zulu, at: Date(timeIntervalSince1970: 200))

        let ordered = Shelf.ordered(try service.shelfItems())

        XCTAssertEqual(ordered.map(\.title), [zulu.displayName, mid.displayName, alpha.displayName])
    }

    func testShelfOrdersNeverPlayedItemsCaseInsensitivelyByTitle() throws {
        _ = try service.registerImported(filename: "Banana.wad", sha1: "b",
                                         kind: WADKind.iwad.rawValue, family: "doom")
        _ = try service.registerImported(filename: "apple.wad", sha1: "a",
                                         kind: WADKind.iwad.rawValue, family: "doom")

        let titles = Shelf.ordered(try service.shelfItems()).map(\.title)

        // `registerImported` titles an unrecognized WAD by its extension-less
        // filename. These two discriminate: a plain `<` on Strings compares
        // UTF-8 and would put "Banana" first, since every capital sorts ahead
        // of every lowercase.
        XCTAssertEqual(titles, ["apple", "Banana"])
    }

    func testShelfMixesBaseGamesAndPresetsInOneOrdering() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i",
                                                kind: WADKind.iwad.rawValue, family: "doom2")
        let preset = try service.createLoadout(name: "Sunlust", iwadID: iwad.id,
                                               pwadIDs: [], dehIDs: [])
        preset.lastPlayed = Date(timeIntervalSince1970: 500)
        try service.saveChanges()

        let ordered = Shelf.ordered(try service.shelfItems())

        // The played preset outranks the never-played base game: kind plays no
        // part in the ordering, which is the point of the unified grid.
        XCTAssertEqual(ordered.map(\.id), ["loadout-\(preset.id)", "wad-\(iwad.id)"])
    }

    // MARK: - Hidden items

    func testHiddenItemIsAbsentFromTheShelf() throws {
        let kept = try service.registerImported(filename: "kept.wad", sha1: "k",
                                                kind: WADKind.iwad.rawValue, family: "doom")
        let removed = try service.registerImported(filename: "removed.wad", sha1: "r",
                                                   kind: WADKind.iwad.rawValue, family: "doom")

        try service.hide(.baseGame(removed))

        let ids = Shelf.ordered(try service.shelfItems()).map(\.id)
        XCTAssertEqual(ids, ["wad-\(kept.id)"])
        XCTAssertEqual(try service.hiddenItems().map(\.id), ["wad-\(removed.id)"])

        // Restore puts it back on the shelf — the round trip Manage's Hidden
        // from Shelf list drives.
        try service.restore(.baseGame(removed))
        XCTAssertEqual(Set(Shelf.ordered(try service.shelfItems()).map(\.id)),
                       ["wad-\(kept.id)", "wad-\(removed.id)"])
    }

    func testHiddenPresetIsAbsentFromTheShelf() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i",
                                                kind: WADKind.iwad.rawValue, family: "doom2")
        let preset = try service.createLoadout(name: "Hidden", iwadID: iwad.id,
                                               pwadIDs: [], dehIDs: [])

        try service.hide(.preset(preset))

        XCTAssertEqual(try service.shelfItems().map(\.id), ["wad-\(iwad.id)"])
    }

    // MARK: - Continue hero

    func testHeroIsTheLastPlayedItemWhenItHasASave() throws {
        let older = try service.registerImported(filename: "older.wad", sha1: "o",
                                                 kind: WADKind.iwad.rawValue, family: "doom")
        let newest = try service.registerImported(filename: "newest.wad", sha1: "n",
                                                  kind: WADKind.iwad.rawValue, family: "doom")
        try service.markPlayed(older, at: Date(timeIntervalSince1970: 100))
        try service.markPlayed(newest, at: Date(timeIntervalSince1970: 200))

        let hero = Shelf.hero(from: try service.shelfItems()) { $0.id == "wad-\(newest.id)" }

        XCTAssertEqual(hero?.id, "wad-\(newest.id)")
    }

    func testHeroIsEmptyWhenNothingHasBeenPlayed() throws {
        _ = try service.registerImported(filename: "unplayed.wad", sha1: "u",
                                         kind: WADKind.iwad.rawValue, family: "doom")

        // Even with a resumable save present, a never-played item is not a
        // "last played" item and gets no hero.
        XCTAssertNil(Shelf.hero(from: try service.shelfItems()) { _ in true })
    }

    func testHeroIsEmptyWhenTheLastPlayedItemHasNoSave() throws {
        let older = try service.registerImported(filename: "older.wad", sha1: "o",
                                                 kind: WADKind.iwad.rawValue, family: "doom")
        let newest = try service.registerImported(filename: "newest.wad", sha1: "n",
                                                  kind: WADKind.iwad.rawValue, family: "doom")
        try service.markPlayed(older, at: Date(timeIntervalSince1970: 100))
        try service.markPlayed(newest, at: Date(timeIntervalSince1970: 200))

        // `older` has a save and `newest` does not. The hero is *the* last
        // played item or nothing — silently resuming a different game than the
        // one you last played would be worse than an empty zone.
        XCTAssertNil(Shelf.hero(from: try service.shelfItems()) { $0.id == "wad-\(older.id)" })
    }

    /// The hero's save predicate in the app is
    /// `PlayableLauncher.continuableSlot(for:library:) != nil`, so the offer and
    /// the launch cannot disagree. This pins that composition against real save
    /// files rather than a stub closure.
    func testHeroUsesTheSameResumableSaveAnswerAsTheLauncher() throws {
        let wad = try service.registerImported(filename: "doom2.wad", sha1: "i",
                                               kind: WADKind.iwad.rawValue, family: "doom2")
        try service.markPlayed(wad, at: Date(timeIntervalSince1970: 300))
        let hasResumableSave = { (item: PlayableItem) -> Bool in
            PlayableLauncher.continuableSlot(for: item, library: self.service) != nil
        }

        XCTAssertNil(Shelf.hero(from: try service.shelfItems(),
                                hasResumableSave: hasResumableSave),
                     "no saves on disk yet, so no hero")

        try writeSaves([("woofsav3.dsg", 400)], forKey: wad.id)

        XCTAssertEqual(Shelf.hero(from: try service.shelfItems(),
                                  hasResumableSave: hasResumableSave)?.id,
                       "wad-\(wad.id)")
    }

    // MARK: - First-launch welcome card

    /// Every case below seeds the real bundled rows first, so "factory state"
    /// here is the state a genuine first launch is in — the two Freedoom IWADs
    /// present and nothing else — rather than an empty store, which no install
    /// is ever in.
    func testWelcomeCardShowsOnAFactoryStateLibrary() throws {
        try service.seedBundledContentIfNeeded()

        XCTAssertTrue(try service.isFactoryState())
        XCTAssertEqual(try zone(), .welcome)
    }

    func testWelcomeCardIsGoneOnceANonBundledItemExists() throws {
        try service.seedBundledContentIfNeeded()
        _ = try service.registerImported(filename: "myown.wad", sha1: "m",
                                         kind: WADKind.iwad.rawValue, family: "doom2")

        // Nothing has been played, so nothing takes the zone over: the card is
        // gone and the zone is simply empty. That is the half of §4's rule an
        // implementation keying the card off "no saves yet" alone would miss.
        XCTAssertFalse(try service.isFactoryState())
        XCTAssertEqual(try zone(), .empty)
    }

    func testWelcomeCardIsGoneOnceABundledGameHasASave() throws {
        try service.seedBundledContentIfNeeded()
        let freedoom = try XCTUnwrap(try service.allWADs()
            .first { $0.filename == "freedoom1.wad" })
        try writeSaves([("woofsav0.dsg", 400)], forKey: freedoom.id)

        // Nothing imported — the save alone ends factory state, which is the
        // other half of "whichever comes first". `lastPlayed` is deliberately
        // unset, so this cannot pass by way of the Continue hero.
        XCTAssertFalse(try service.isFactoryState())
        XCTAssertEqual(try zone(), .empty)
    }

    /// The transition §4 hands off to §2: once there is something to resume,
    /// the zone is the Continue hero rather than either of the above.
    func testContinueHeroTakesTheZoneOverFromTheWelcomeCard() throws {
        try service.seedBundledContentIfNeeded()
        let freedoom = try XCTUnwrap(try service.allWADs()
            .first { $0.filename == "freedoom2.wad" })
        try service.markPlayed(freedoom, at: Date(timeIntervalSince1970: 700))
        try writeSaves([("woofsav3.dsg", 800)], forKey: freedoom.id)

        XCTAssertEqual(try zone(), .resume(.baseGame(freedoom)))
    }

    /// A mod is never a shelf item, so a rule written over `shelfItems()` would
    /// keep greeting someone who has already brought their own files in.
    func testAnImportedModEndsFactoryStateThoughItNeverReachesTheShelf() throws {
        try service.seedBundledContentIfNeeded()
        _ = try service.registerImported(filename: "sunlust.wad", sha1: "s",
                                         kind: WADKind.pwad.rawValue, family: "doom2")

        XCTAssertFalse(try service.shelfItems().contains { $0.title == "sunlust" },
                       "a PWAD is not directly playable and never reaches the shelf")
        XCTAssertFalse(try service.isFactoryState())
        XCTAssertEqual(try zone(), .empty)
    }

    // MARK: - Tap resolution

    func testTapWithASaveOpensTheActionSheet() throws {
        let wad = try service.registerImported(filename: "doom2.wad", sha1: "i",
                                               kind: WADKind.iwad.rawValue, family: "doom2")
        try writeSaves([("woofsav3.dsg", 400)], forKey: wad.id)

        let action = Shelf.tapAction(for: .baseGame(wad)) {
            PlayableLauncher.continuableSlot(for: $0, library: self.service) != nil
        }

        XCTAssertEqual(action, .actionSheet)
    }

    func testTapWithoutASaveLaunchesStraightIntoTheGame() throws {
        let wad = try service.registerImported(filename: "doom2.wad", sha1: "i",
                                               kind: WADKind.iwad.rawValue, family: "doom2")

        let action = Shelf.tapAction(for: .baseGame(wad)) {
            PlayableLauncher.continuableSlot(for: $0, library: self.service) != nil
        }

        XCTAssertEqual(action, .launchNewGame)
    }

    func testTapWithOnlyUnloadableSavesLaunchesStraightIntoTheGame() throws {
        let wad = try service.registerImported(filename: "doom2.wad", sha1: "i",
                                               kind: WADKind.iwad.rawValue, family: "doom2")
        // A file in the saves directory the engine cannot boot by slot: the
        // sheet would offer a Continue that could not run.
        try writeSaves([("notes.txt", 400)], forKey: wad.id)

        let action = Shelf.tapAction(for: .baseGame(wad)) {
            PlayableLauncher.continuableSlot(for: $0, library: self.service) != nil
        }

        XCTAssertEqual(action, .launchNewGame)
    }

    // MARK: - Helpers

    /// The hero zone exactly as `ShelfView.refresh()` resolves it: the same
    /// three service answers, in the same composition. Going through this
    /// rather than passing literals means the welcome-card cases above are
    /// tests of the screen's behaviour against a real store, not of a rule
    /// handed its own conclusion.
    private func zone() throws -> Shelf.HeroZone {
        Shelf.heroZone(from: try service.shelfItems(),
                       isFactoryState: try service.isFactoryState()) {
            PlayableLauncher.continuableSlot(for: $0, library: self.service) != nil
        }
    }

    /// Writes real save files into `key`'s saves directory and arranges for the
    /// directory to be removed again — it lives under the app's Documents
    /// directory, shared by every test.
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
}
