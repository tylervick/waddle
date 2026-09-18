import Foundation
import SwiftData

@Model
final class WADFile {
    @Attribute(.unique) var id: UUID
    var filename: String
    var displayName: String
    var kindRaw: String
    var sha1: String
    var gameFamilyRaw: String
    var isBundled: Bool
    var importDate: Date
    /// Whether the WAD's directory carries any map lumps (`WADParser.mapFormat`).
    /// Decides a PWAD's role (spec §2.1). Defaulted so existing stores migrate
    /// lightweight; `LibraryService.migrateToGames` fills it for present files.
    var hasMaps: Bool = false
    /// Legacy: moved to `Game`. Read only by `LibraryService.migrateToGames`; dropped in a later release (spec §5).
    var lastPlayed: Date?
    /// Legacy: moved to `Game`. Read only by `LibraryService.migrateToGames`; dropped in a later release (spec §5).
    var schemeOverrideRaw: String?
    /// Legacy: moved to `Game`. Read only by `LibraryService.migrateToGames`; dropped in a later release (spec §5).
    var isHidden: Bool = false

    init(id: UUID = UUID(), filename: String, displayName: String, kindRaw: String,
         sha1: String, gameFamilyRaw: String, isBundled: Bool = false,
         importDate: Date = .now, hasMaps: Bool = false) {
        self.id = id
        self.filename = filename
        self.displayName = displayName
        self.kindRaw = kindRaw
        self.sha1 = sha1
        self.gameFamilyRaw = gameFamilyRaw
        self.isBundled = isBundled
        self.importDate = importDate
        self.lastPlayed = nil
        self.schemeOverrideRaw = nil
        self.hasMaps = hasMaps
    }

    var gameFamily: GameFamily { GameFamily(rawValue: gameFamilyRaw) ?? .unknown }
}

/// What a file is *for* (spec §2.1), derived and never stored: a base is an
/// IWAD, a map set is a PWAD with maps and becomes a game, and everything else
/// is an add-on that only ever attaches to a game.
enum FileRole: Equatable {
    case base
    case mapSet
    case addOn
}

extension WADFile {
    var kind: WADKind? { WADKind(rawValue: kindRaw) }

    var role: FileRole {
        switch kind {
        case .iwad: return .base
        case .pwad: return hasMaps ? .mapSet : .addOn
        case .deh, .none: return .addOn
        }
    }
}
