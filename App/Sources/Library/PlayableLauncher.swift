import Foundation

struct LaunchPlan {
    let arguments: [String]
    let scheme: TouchControlScheme
}

enum PlayableLaunchError: Error, Equatable {
    case missingWAD(UUID)
}

/// Turns a `PlayableItem` into a ready-to-run `LaunchPlan`: builds engine argv,
/// resolves the effective touch scheme (per-item override ?? global), and
/// stamps `lastPlayed`. Base games launch ephemerally (no persisted Loadout),
/// keyed for saves by their own `WADFile.id`.
@MainActor
enum PlayableLauncher {
    static func prepare(_ item: PlayableItem, library: LibraryService,
                        at date: Date = .now) throws -> LaunchPlan {
        let scheme = TouchControlScheme.effective(override: item.schemeOverrideRaw)
        switch item {
        case .baseGame(let wad):
            let args = try LoadoutArguments.build(iwadURL: library.fileURL(for: wad),
                                                  saveID: wad.id)
            try library.markPlayed(wad, at: date)
            return LaunchPlan(arguments: args, scheme: scheme)
        case .preset(let loadout):
            let args = try LoadoutArguments.build(loadout: loadout) { id in
                guard let wad = try library.wad(id: id) else {
                    throw PlayableLaunchError.missingWAD(id)
                }
                return library.fileURL(for: wad)
            }
            loadout.lastPlayed = date
            try library.saveChanges()
            return LaunchPlan(arguments: args, scheme: scheme)
        }
    }
}
