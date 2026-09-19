import Foundation
import SwiftData

/// What you play (spec §2.2): one base IWAD, zero or more other files in load
/// order, and everything that used to be split between an IWAD `WADFile` and
/// the old preset model — compat, touch-layout override, hidden flag, last
/// played. Its `id` is the saves key: `LibraryService.savesDirectory(forGameID:)`.
///
/// A base game (`isBaseGame`) is the IWAD's own game. Its `id` *is* the IWAD's
/// `WADFile.id` — `baseGame(for:)` is the only way one is made — which is what
/// keeps `Documents/Saves/<id>/` where the pre-`Game` build left it. A base
/// game cannot be deleted (hide it) and its base cannot change.
@Model
final class Game {
    @Attribute(.unique) var id: UUID
    var name: String
    /// An IWAD `WADFile`; `nil` means unpaired — the tile shows "Needs a base
    /// game" (plan 2) and the launcher refuses with `LaunchArgumentsError.missingBase`.
    var baseID: UUID?
    /// Every non-base file, in engine load order. Each entry's role comes from
    /// its `WADFile.role`; argument building emits `-file` for WADs and `-deh`
    /// for patches, each group in this order.
    var fileIDs: [UUID]
    var complevel: String?
    /// `TouchControlScheme` raw value; nil = the global default.
    var schemeOverrideRaw: String?
    /// Off the shelf, reversibly. The row, its files and its saves persist.
    var isHidden: Bool
    var lastPlayed: Date?
    var createdAt: Date
    var isBaseGame: Bool

    init(id: UUID = UUID(), name: String, baseID: UUID?, fileIDs: [UUID] = [],
         complevel: String? = nil, schemeOverrideRaw: String? = nil,
         isHidden: Bool = false, lastPlayed: Date? = nil,
         createdAt: Date = .now, isBaseGame: Bool = false) {
        self.id = id
        self.name = name
        self.baseID = baseID
        self.fileIDs = fileIDs
        self.complevel = complevel
        self.schemeOverrideRaw = schemeOverrideRaw
        self.isHidden = isHidden
        self.lastPlayed = lastPlayed
        self.createdAt = createdAt
        self.isBaseGame = isBaseGame
    }

    /// The IWAD's own game, sharing the IWAD's id. Not inserted — callers do that.
    static func baseGame(for iwad: WADFile) -> Game {
        Game(id: iwad.id, name: iwad.displayName, baseID: iwad.id, isBaseGame: true)
    }
}
