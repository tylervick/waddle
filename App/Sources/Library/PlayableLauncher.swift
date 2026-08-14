import Foundation

struct LaunchPlan {
    let arguments: [String]
    let scheme: TouchControlScheme
}

enum PlayableLaunchError: Error, Equatable {
    case missingWAD(UUID)
}

/// How a launch enters the game.
enum LaunchMode {
    /// The engine's own entry point: title screen, then the player's menus.
    case newGame
    /// Straight into the item's most recently modified loadable save, via
    /// `-loadgame` (see `EngineSaveSlot`). Falls back to `.newGame`'s argv when
    /// the item has no loadable save, so an item without saves is unchanged.
    case continueNewest
}

/// Turns a `PlayableItem` into a ready-to-run `LaunchPlan`: builds engine argv,
/// resolves the effective touch scheme (per-item override ?? global), and
/// stamps `lastPlayed`. Base games launch ephemerally (no persisted Loadout),
/// keyed for saves by their own `WADFile.id`.
@MainActor
enum PlayableLauncher {
    static func prepare(_ item: PlayableItem, library: LibraryService,
                        mode: LaunchMode = .newGame,
                        at date: Date = .now) throws -> LaunchPlan {
        let scheme = TouchControlScheme.effective(override: item.schemeOverrideRaw)
        let loadGameSlot = mode == .continueNewest ? continuableSlot(for: item, library: library) : nil
        switch item {
        case .baseGame(let wad):
            let args = try LoadoutArguments.build(iwadURL: library.fileURL(for: wad),
                                                  saveID: wad.id,
                                                  loadGameSlot: loadGameSlot)
            try library.markPlayed(wad, at: date)
            return LaunchPlan(arguments: args, scheme: scheme)
        case .preset(let loadout):
            let args = try LoadoutArguments.build(loadout: loadout, resolve: { id in
                guard let wad = try library.wad(id: id) else {
                    throw PlayableLaunchError.missingWAD(id)
                }
                return library.fileURL(for: wad)
            }, loadGameSlot: loadGameSlot)
            loadout.lastPlayed = date
            try library.saveChanges()
            return LaunchPlan(arguments: args, scheme: scheme)
        }
    }

    /// The `-loadgame` slot a Continue on `item` would resume, or `nil` when it
    /// has nothing resumable. Also what the UI asks to decide whether to offer
    /// Continue at all, so the offer and the launch can never disagree.
    static func continuableSlot(for item: PlayableItem, library: LibraryService) -> Int? {
        EngineSaveSlot.newestLoadGameArgument(in: library.saveSlots(forKey: item.savesKey))
    }
}
