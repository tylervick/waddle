import Foundation

/// A directly-playable entry in the Play grid: a base game (an IWAD `WADFile`)
/// or a saved preset (`Loadout`). A value wrapper for display/launch — the
/// underlying model is retained for mutation/launch by callers.
enum PlayableItem: Identifiable {
    case baseGame(WADFile)
    case preset(Loadout)

    var id: String {
        switch self {
        case .baseGame(let w): return "wad-\(w.id)"
        case .preset(let l): return "loadout-\(l.id)"
        }
    }

    var isBaseGame: Bool { if case .baseGame = self { return true } else { return false } }

    /// The saves-directory key for this item: a base game keys its saves off
    /// the IWAD's own id, a preset off the `Loadout`'s id. Matches the `saveID`
    /// `LoadoutArguments.build` hands to
    /// `LibraryService.savesDirectory(forLoadoutID:)`, so a launch and a saves
    /// listing always agree on which directory belongs to this item.
    var savesKey: UUID {
        switch self {
        case .baseGame(let w): return w.id
        case .preset(let l): return l.id
        }
    }

    var title: String {
        switch self {
        case .baseGame(let w): return w.displayName
        case .preset(let l): return l.name
        }
    }

    var lastPlayed: Date? {
        switch self {
        case .baseGame(let w): return w.lastPlayed
        case .preset(let l): return l.lastPlayed
        }
    }

    var schemeOverrideRaw: String? {
        switch self {
        case .baseGame(let w): return w.schemeOverrideRaw
        case .preset(let l): return l.schemeOverrideRaw
        }
    }
}
