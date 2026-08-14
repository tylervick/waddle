import Foundation

/// Maps a file's content SHA-1 to the title its game actually ships under, so
/// a recognized import reads "DOOM II: Hell on Earth" on the Play tab instead
/// of whatever the file on disk happened to be called.
///
/// Keyed on content, never on filename, and that is the whole point: each
/// predecessor app (tomkidd DOOM-iOS lineage) was built as its game and
/// carried that identity in the binary, so the equivalent courtesy here has to
/// survive a user renaming `doom2.wad` to `d2.wad` before importing it.
/// Import already computes this exact hash to dedupe on, so recognition costs
/// nothing extra.
///
/// An unrecognized hash is not an error — `title(forSHA1:)` returns nil and
/// the caller keeps its filename-derived name. That is the permanent, normal
/// case: every PWAD, every mod, and every commercial release not listed here
/// lands there.
enum IWADCatalog {
    /// SHA-1 (lowercase hex) → published game title.
    ///
    /// A game can legitimately ship under more than one hash — the DOS 1.9
    /// Final Doom release and the later GOG/anthology re-release differ in
    /// content — so both are listed against the same title rather than
    /// picking a winner.
    ///
    /// Every entry below was cross-checked against at least two independent
    /// published sources, with its MD5 (noted in the trailing comment) used as
    /// the corroborating identifier, because a wrong hash here fails silently:
    /// it does not break a test, it just quietly never matches a real file.
    /// See `docs/learnings/content-hash-tables-fail-silently.md`.
    static let titlesBySHA1: [String: String] = [
        // doom.wad, The Ultimate DOOM (1.9ud) — md5 c4fe9fd920207691a9f493668e0a2083
        "9b07b02ab3c275a6a7570c3f73cc20d63a0e3833": "The Ultimate DOOM",
        // doom1.wad, DOOM shareware (1.9) — md5 f0cefca49926d00903cf57551d901abe
        "5b2e249b9c5133ec987b3ea77596381dc0d6bc1d": "DOOM (Shareware)",
        // doom2.wad, DOOM II: Hell on Earth (1.9) — md5 25e1459ca71d321525f84628f45ca8cd
        "7ec7652fcfce8ddc6e801839291f0e28ef1d5ae7": "DOOM II: Hell on Earth",
        // tnt.wad, Final Doom 1.9 — md5 4e158d9953c79ccf97bd0663244cc6b6
        "9fbc66aedef7fe3bae0986cdb9323d2b8db4c9d3": "TNT: Evilution",
        // tnt.wad, GOG/anthology re-release — md5 1d39e405bf6ee3df69a8d2646c8d5c49
        "4a65c8b960225505187c36040b41a40b152f8f3e": "TNT: Evilution",
        // plutonia.wad, GOG/anthology re-release — md5 3493be7e1e2588bc9c8b31eab2587a04
        "f131cbe1946d7fddb3caec4aa258c83399c21e60": "The Plutonia Experiment",
    ]

    /// The published title for `sha1`, or nil when the content is not a
    /// recognized commercial IWAD.
    ///
    /// Case-folded on the way in: `WADStore.sha1` renders lowercase hex today,
    /// but nothing in the type system says a caller must, and a lookup that
    /// silently stopped recognizing every game the day someone handed it
    /// uppercase would be a miserable bug to find.
    static func title(forSHA1 sha1: String) -> String? {
        titlesBySHA1[sha1.lowercased()]
    }
}
