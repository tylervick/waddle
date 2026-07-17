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
    }
}
