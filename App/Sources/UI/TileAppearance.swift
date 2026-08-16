import CoreGraphics
import Foundation

/// What a tile draws where its art goes.
///
/// Pure and separate from the view for the same reason `Shelf` is (the repo has
/// no view harness): spec §5 is specific about this rule — "items with no
/// decodable art get a flat dark tile with the title — no fake art" — and it is
/// the rule, not the drawing, that is worth a test. `TitleArtView` reads its
/// image through `resolve`, so a change here cannot leave the screen behind.
enum TileAppearance: Equatable {
    /// A decoded TITLEPIC fills the tile.
    case art
    /// Nothing decoded: the flat elevated-surface tile, with the tile's own
    /// scrim carrying the title.
    case flatTitle

    /// Still-loading resolves to `.flatTitle` as well, and deliberately: the
    /// flat tile is where a failed decode settles, so a tile that is mid-decode
    /// shows the shape it may keep instead of flashing a stand-in it then
    /// replaces. This is the behaviour that replaced `GeneratedArtView`'s
    /// monogram placeholder — a generated image reads as the game's own
    /// artwork, which is a small lie about what the library holds.
    static func resolve(decodedArt: CGImage?) -> TileAppearance {
        decodedArt == nil ? .flatTitle : .art
    }
}

/// VoiceOver labels for the shelf's items (spec §5: "DOOM II, last played
/// yesterday"). Pure, for the same reason as `TileAppearance` above.
enum TileAccessibility {
    /// The title, plus when it was last played when there is such a date.
    ///
    /// A never-played item reads as just its title: there is nothing to phrase,
    /// and "never played" on every tile of a fresh library is noise in front of
    /// the one thing the label exists to say.
    static func label(title: String,
                      lastPlayed: Date?,
                      now: Date = Date(),
                      locale: Locale = .autoupdatingCurrent) -> String {
        guard let lastPlayed else { return title }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        // `.named` is what turns "1 day ago" into "yesterday", which is the
        // phrasing the spec's own example uses.
        formatter.dateTimeStyle = .named
        return "\(title), last played \(formatter.localizedString(for: lastPlayed, relativeTo: now))"
    }

    static func label(for item: PlayableItem,
                      now: Date = Date(),
                      locale: Locale = .autoupdatingCurrent) -> String {
        label(title: item.title, lastPlayed: item.lastPlayed, now: now, locale: locale)
    }
}
