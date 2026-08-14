import Foundation
import SwiftData

@Model
final class Loadout {
    @Attribute(.unique) var id: UUID
    var name: String
    var iwadID: UUID
    var pwadIDs: [UUID]
    var dehIDs: [UUID]
    var complevel: String?
    var lastPlayed: Date?
    var createdAt: Date
    /// Optional per-preset touch-scheme override (TouchControlScheme raw
    /// value); nil = use the global default.
    var schemeOverrideRaw: String?
    /// Removed from the Play shelf, reversibly (spec §4). The row and its saves
    /// persist; see `WADFile.isHidden`. Defaulted in place so existing stores
    /// migrate lightweight.
    var isHidden: Bool = false

    init(id: UUID = UUID(), name: String, iwadID: UUID, pwadIDs: [UUID] = [],
         dehIDs: [UUID] = [], complevel: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.iwadID = iwadID
        self.pwadIDs = pwadIDs
        self.dehIDs = dehIDs
        self.complevel = complevel
        self.lastPlayed = nil
        self.createdAt = createdAt
        self.schemeOverrideRaw = nil
    }
}
