import Foundation

/// Which installed IWAD a newly imported map set loads under (spec §4.1).
/// Pure so the preference order is a test, not a comment.
enum Pairing {
    struct Candidate {
        let file: WADFile
        /// The IWAD's own base game's `lastPlayed`.
        let lastPlayed: Date?
    }

    /// Same family only; an imported IWAD beats bundled Freedoom; among several
    /// imported, the most recently played, then by title. `.unknown` never
    /// pairs. Runs once at import and is never revisited.
    static func chooseBase(forFamily family: GameFamily, among candidates: [Candidate]) -> WADFile? {
        guard family != .unknown else { return nil }
        let matching = candidates.filter { $0.file.gameFamily == family }
        let imported = matching.filter { !$0.file.isBundled }
        let pool = imported.isEmpty ? matching : imported
        return pool.sorted { lhs, rhs in
            switch (lhs.lastPlayed, rhs.lastPlayed) {
            case let (l?, r?) where l != r: return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs.file.displayName.localizedStandardCompare(rhs.file.displayName) == .orderedAscending
            }
        }.first?.file
    }
}
