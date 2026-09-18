import Foundation

enum GameLaunchError: Error, Equatable {
    case missingWAD(UUID)
}

/// Turns a `Game` into a ready-to-run `LaunchPlan`: builds engine argv,
/// resolves the effective touch scheme (per-game override ?? global), and
/// stamps `lastPlayed`. Saves are keyed by the game's id.
@MainActor
enum GameLauncher {
    static func prepare(_ game: Game, library: LibraryService,
                        mode: LaunchMode = .newGame,
                        at date: Date = .now) throws -> LaunchPlan {
        let scheme = TouchControlScheme.effective(override: game.schemeOverrideRaw)
        let loadGameSlot = mode == .continueNewest ? continuableSlot(for: game, library: library) : nil
        let args = try LaunchArguments.build(game: game, resolve: { id in
            guard let wad = try library.wad(id: id), let kind = wad.kind else {
                throw GameLaunchError.missingWAD(id)
            }
            return ResolvedFile(url: library.fileURL(for: wad), kind: kind)
        }, loadGameSlot: loadGameSlot)
        try library.markPlayed(game, at: date)
        return LaunchPlan(arguments: args, scheme: scheme)
    }

    /// The `-loadgame` slot a Continue on `game` would resume, or `nil` when it
    /// has nothing resumable. Also what the UI asks to decide whether to offer
    /// Continue at all, so the offer and the launch can never disagree.
    static func continuableSlot(for game: Game, library: LibraryService) -> Int? {
        EngineSaveSlot.newestLoadGameArgument(in: library.saveSlots(forKey: game.id))
    }
}
