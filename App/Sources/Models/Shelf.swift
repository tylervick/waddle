import Foundation

/// The shelf's composition rules, factored out of `ShelfView` so they can be
/// tested without a view harness (the repo has none -- see the note in
/// `LibraryView.deleting`). `ShelfView` calls these and does nothing else to
/// decide what it shows, so a test over these functions is a test of the
/// screen's behaviour rather than of a helper the screen might bypass.
///
/// "Has a save" throughout means *resumable* save -- one the engine can boot
/// straight into via `-loadgame`. `PlayableLauncher.continuableSlot(for:library:)`
/// is the single source of that answer, so the hero, the tap sheet, and the
/// launch itself can never disagree about whether Continue is possible.
enum Shelf {
    /// What a tap on a tile does.
    enum TapAction: Equatable {
        /// The item has a resumable save: Continue / New Game / Details.
        case actionSheet
        /// Nothing to resume: straight to the engine's title screen, as before.
        case launchNewGame
    }

    /// Shelf order: everything played, most recent first, then everything else
    /// alphabetically. A returning player's games collect at the front and
    /// Freedoom recedes once real games arrive (spec §2).
    static func ordered(_ items: [PlayableItem]) -> [PlayableItem] {
        let played: [PlayableItem] = items.filter { (item: PlayableItem) -> Bool in
            item.lastPlayed != nil
        }.sorted { (lhs: PlayableItem, rhs: PlayableItem) -> Bool in
            let left: Date = lhs.lastPlayed ?? Date.distantPast
            let right: Date = rhs.lastPlayed ?? Date.distantPast
            return left > right
        }
        let unplayed: [PlayableItem] = items.filter { (item: PlayableItem) -> Bool in
            item.lastPlayed == nil
        }.sorted { (lhs: PlayableItem, rhs: PlayableItem) -> Bool in
            lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return played + unplayed
    }

    /// The Continue hero, or `nil` when the zone stays empty.
    ///
    /// Deliberately strict: it is *the* last-played item or nothing. If the most
    /// recently played game has no resumable save, the hero is empty even when
    /// some older game does have one -- a hero that quietly resumed a different
    /// game than the one you last played would be worse than no hero.
    static func hero(from items: [PlayableItem],
                     hasResumableSave: (PlayableItem) -> Bool) -> PlayableItem? {
        let played: [PlayableItem] = items.filter { (item: PlayableItem) -> Bool in
            item.lastPlayed != nil
        }
        let last: PlayableItem? = played.max { (lhs: PlayableItem, rhs: PlayableItem) -> Bool in
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
        case resume(PlayableItem)
        /// Nothing -- played, but nothing resumable.
        case empty

        // `PlayableItem` wraps SwiftData models and is not `Equatable`; its
        // `id` is what identifies an item everywhere else on this screen (it
        // is the `Identifiable` conformance the grid's `ForEach` runs on), so
        // it is what equality means here too.
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
    static func heroZone(from items: [PlayableItem],
                         isFactoryState: Bool,
                         hasResumableSave: (PlayableItem) -> Bool) -> HeroZone {
        if let item = hero(from: items, hasResumableSave: hasResumableSave) {
            return .resume(item)
        }
        return isFactoryState ? .welcome : .empty
    }

    /// Tap resolution for a tile (spec §2's tile interactions).
    static func tapAction(for item: PlayableItem,
                          hasResumableSave: (PlayableItem) -> Bool) -> TapAction {
        hasResumableSave(item) ? .actionSheet : .launchNewGame
    }
}
