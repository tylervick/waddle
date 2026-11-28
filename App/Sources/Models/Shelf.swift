import Foundation

/// The shelf's composition rules, factored out of `ShelfView` so they can be
/// tested without a view harness (the repo has none -- see the note in
/// `FilesView.deleting`). `ShelfView` calls these and does nothing else to
/// decide what it shows, so a test over these functions is a test of the
/// screen's behaviour rather than of a helper the screen might bypass.
///
/// "Has a save" throughout means *resumable* save -- one the engine can boot
/// straight into via `-loadgame`. `GameLauncher.continuableSlot(for:library:)`
/// is the single source of that answer, so the hero, the tap sheet, and the
/// launch itself can never disagree about whether Continue is possible.
enum Shelf {
    /// What a tap on a tile does.
    enum TapAction: Equatable {
        /// The item has a resumable save: Continue / New Game / Details.
        case actionSheet
        /// Nothing to resume: straight to the engine's title screen, as before.
        case launchNewGame
        /// Unpaired (`baseID == nil`): nothing to launch; the page is where the
        /// base gets chosen (spec §3.1).
        case openPage
    }

    /// Shelf order: everything played, most recent first, then everything else
    /// alphabetically. A returning player's games collect at the front and
    /// Freedoom recedes once real games arrive (spec §2).
    static func ordered(_ items: [Game]) -> [Game] {
        let played: [Game] = items.filter { (game: Game) -> Bool in
            game.lastPlayed != nil
        }.sorted { (lhs: Game, rhs: Game) -> Bool in
            let left: Date = lhs.lastPlayed ?? Date.distantPast
            let right: Date = rhs.lastPlayed ?? Date.distantPast
            return left > right
        }
        let unplayed: [Game] = items.filter { (game: Game) -> Bool in
            game.lastPlayed == nil
        }.sorted { (lhs: Game, rhs: Game) -> Bool in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return played + unplayed
    }

    /// The game whose page the lower half of a half-open iPhone Duo shows
    /// while nothing else is open there (issue #429; the owner's choice of
    /// 2026-11-21): the last one played, so Play is under the thumb.
    ///
    /// That is the first game in shelf order, which also answers the library
    /// nobody has played yet: the first tile, the one the eye is on. Nil only
    /// when the shelf has no game at all. Unlike `hero`, a save is not asked
    /// for: the page has New Game as well as Continue.
    static func restingGame(from ordered: [Game]) -> Game? { ordered.first }

    /// The hero zone as the shelf shows it. In two halves the Continue hero
    /// is left out (same choice, same day): the page in the lower half is
    /// that game's, with the same Continue and New Game, and the two would
    /// be on screen twice. The game goes back among the tiles, which is what
    /// `gridItems` does for an empty zone. The welcome card stays; flat,
    /// nothing changes.
    static func heroZone(_ zone: HeroZone, inTwoHalves: Bool) -> HeroZone {
        if inTwoHalves, case .resume = zone { return .empty }
        return zone
    }

    /// The Continue hero, or `nil` when the zone stays empty.
    ///
    /// Deliberately strict: it is *the* last-played item or nothing. If the most
    /// recently played game has no resumable save, the hero is empty even when
    /// some older game does have one -- a hero that quietly resumed a different
    /// game than the one you last played would be worse than no hero.
    static func hero(from items: [Game],
                     hasResumableSave: (Game) -> Bool) -> Game? {
        let played: [Game] = items.filter { (game: Game) -> Bool in
            game.lastPlayed != nil
        }
        let last: Game? = played.max { (lhs: Game, rhs: Game) -> Bool in
            let left: Date = lhs.lastPlayed ?? Date.distantPast
            let right: Date = rhs.lastPlayed ?? Date.distantPast
            return left < right
        }
        guard let last else { return nil }
        return hasResumableSave(last) ? last : nil
    }

    /// What the hero zone shows. One value rather than two independent
    /// questions, so the welcome card and the Continue hero cannot both be on
    /// screen and cannot both be missing when one of them is owed.
    enum HeroZone: Equatable {
        /// First launch: the welcome card (spec §4).
        case welcome
        /// The Continue hero for this item (spec §2).
        case resume(Game)
        /// Nothing -- played, but nothing resumable.
        case empty

        // `Game` is a SwiftData model and is not `Equatable`; its `id` is
        // what identifies a game everywhere else on this screen, so it is
        // what equality means here too.
        static func == (lhs: HeroZone, rhs: HeroZone) -> Bool {
            switch (lhs, rhs) {
            case (.welcome, .welcome), (.empty, .empty): return true
            case (.resume(let left), .resume(let right)): return left.id == right.id
            default: return false
            }
        }
    }

    /// Resolves the hero zone (spec §§2, 4): the welcome card only while the
    /// library is factory-state, the Continue hero once §2's rule is met, and
    /// otherwise nothing.
    ///
    /// The two states are mutually exclusive by construction -- a resumable
    /// save is a save, so a library with a hero is not a factory-state one --
    /// and the hero is nevertheless checked first on purpose: if they ever did
    /// disagree, a returning player should be handed their game back rather
    /// than greeted as a new arrival.
    static func heroZone(from items: [Game],
                         isFactoryState: Bool,
                         hasResumableSave: (Game) -> Bool) -> HeroZone {
        if let game = hero(from: items, hasResumableSave: hasResumableSave) {
            return .resume(game)
        }
        return isFactoryState ? .welcome : .empty
    }

    /// Tap resolution for a tile (spec §2's tile interactions).
    static func tapAction(for game: Game,
                          hasResumableSave: (Game) -> Bool) -> TapAction {
        guard game.baseID != nil else { return .openPage }
        return hasResumableSave(game) ? .actionSheet : .launchNewGame
    }

    /// What the grid shows under the hero zone: everything in shelf order,
    /// minus the item the Continue hero is already presenting (spec §2,
    /// amended 2026-08-21). Before the amendment the hero's game appeared
    /// twice on one screen — huge above the fold and again as the first tile
    /// directly beneath itself. Every interaction the removed tile offered
    /// moves onto the hero: tap is Continue, and the hero now carries the
    /// same long-press context menu a tile has, so New Game, Details and
    /// Remove stay exactly one gesture away.
    static func gridItems(from items: [Game], heroZone: HeroZone) -> [Game] {
        let ordered = self.ordered(items)
        guard case .resume(let hero) = heroZone else { return ordered }
        return ordered.filter { (game: Game) -> Bool in
            game.id != hero.id
        }
    }

    /// Whether the grid ends with the ghost "Add Games" hint tile (spec §5,
    /// amended 2026-08-21). Shown while the library is small enough that the
    /// shelf is mostly empty page — the hint fills the next natural slot in
    /// the grid's rhythm and gives the dark field below it a reason to read
    /// as intentional. It disappears once real games occupy the space, so a
    /// full shelf is never haunted by a permanent ad for the importer.
    ///
    /// The threshold counts *library items*, not grid tiles: a hero taking
    /// its game out of the grid does not change how full the library is.
    static func showsAddHint(itemCount: Int) -> Bool {
        itemCount < 4
    }

    /// Whether the shelf offers Freedoom with its Get Freedoom tile (#552):
    /// exactly when the library has neither Freedoom 0.13.0 WAD as a file
    /// that is there, bundled or stored.
    ///
    /// It asks the files, not the shelf. A Freedoom the player hid is
    /// still there, so nothing is offered (Hidden Games brings it back); one
    /// of the two deleted was deliberate, so nothing is offered either. Both
    /// gone (deleted, or rows released from a bundle that no longer ships
    /// them, #503) offers it again, and the download restores released rows
    /// under their own ids, saves and all.
    ///
    /// `tileHidden` is the player's Hide from Shelf on the tile itself: then
    /// nothing is offered, whatever the files, until they restore the tile
    /// from Hidden Games. It hides the offer only; the games are untouched.
    static func offersFreedoom(files: [WADFile], isPresent: (WADFile) -> Bool,
                               tileHidden: Bool = false) -> Bool {
        !tileHidden && freedoomIsMissing(files: files, isPresent: isPresent)
    }

    /// Whether neither Freedoom 0.13.0 WAD is there as a file: what the
    /// tile would offer to fix, hidden or not.
    static func freedoomIsMissing(files: [WADFile], isPresent: (WADFile) -> Bool) -> Bool {
        !files.contains { FreedoomRelease.wadSHA1s.contains($0.sha1.lowercased()) && isPresent($0) }
    }
}
