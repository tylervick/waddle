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

    /// Tap resolution for a tile (spec §2's tile interactions).
    static func tapAction(for item: PlayableItem,
                          hasResumableSave: (PlayableItem) -> Bool) -> TapAction {
        hasResumableSave(item) ? .actionSheet : .launchNewGame
    }
}
