import Foundation

/// Which installed IWAD a newly imported map set loads under (spec §4.1).
/// Pure so the preference order is a test, not a comment.
enum Pairing {
    struct Candidate {
        let file: WADFile
        /// The IWAD's own base game's `lastPlayed`.
        let lastPlayed: Date?
        /// False when the IWAD's file is missing from disk — a Freedoom the
        /// app no longer bundles (issue #503), or an import deleted out of
        /// band. Such a base cannot launch until it is restored.
        var fileIsPresent: Bool = true
    }

    /// Same family only; a base whose file is present beats one whose file is
    /// missing; then an imported IWAD beats bundled Freedoom; among several
    /// imported, the most recently played, then by title. `.unknown` never
    /// pairs. Runs once at import and is never revisited.
    ///
    /// A missing base is still chosen when it is the family's only one: the
    /// row survives so it can be restored, and the map set then plays.
    static func chooseBase(forFamily family: GameFamily, among candidates: [Candidate]) -> WADFile? {
        guard family != .unknown else { return nil }
        let sameFamily = candidates.filter { $0.file.gameFamily == family }
        let present = sameFamily.filter(\.fileIsPresent)
        let matching = present.isEmpty ? sameFamily : present
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
