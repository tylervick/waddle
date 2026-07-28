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
    var lastPlayed: Date?
    /// Optional per-item touch-scheme override (TouchControlScheme raw value);
    /// nil = use the global default. Only meaningful for playable IWADs.
    var schemeOverrideRaw: String?

    init(id: UUID = UUID(), filename: String, displayName: String, kindRaw: String,
         sha1: String, gameFamilyRaw: String, isBundled: Bool = false,
         importDate: Date = .now) {
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
    }

    var gameFamily: GameFamily { GameFamily(rawValue: gameFamilyRaw) ?? .unknown }
}
