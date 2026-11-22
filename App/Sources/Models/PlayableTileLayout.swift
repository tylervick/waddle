import CoreGraphics

/// Pure geometry for a shelf tile: the shape it takes, how much of it the
/// title scrim may cover, and how much of TITLEPIC survives being filled into
/// it. Same shape as `ShelfHeroLayout` and `PlayableDetailLayout`, and tested
/// the same way — over supplied bounds rather than through a rendered screen.
///
/// ## Why the scrim needs a budget
///
/// The tile shape and the scrim were set independently, and the scrim did not
/// scale with the tile. That was survivable while tiles were 3:4 — a two-column
/// iPhone tile was 172 × 229 pt and the scrim's 60 pt was a quarter of it — and
/// stopped being survivable at 4:3, where the same tile is 172 × 129 pt and the
/// same 60 pt scrim covers 47% of the card for one line of text.
///
/// So the paddings live here rather than as literals in `PlayableTileView`, and
/// `scrimHeight` computes from the same numbers the view draws with. A test can
/// then assert the share without rendering anything, and the value it asserts
/// is the value the view uses.
enum PlayableTileLayout {
    /// Space above the title inside the scrim. This is the lever: the scrim's
    /// height is one line of type plus these two paddings, and the top one is
    /// the only part of it with room to give. It was 28 pt when tiles were
    /// portrait, which is what pushed the scrim over the ceiling below once
    /// they became 4:3.
    static let scrimTopPadding: CGFloat = 16

    /// Space below the title. Unchanged: it is already tight enough that the
    /// type would touch the tile's rounded bottom edge if it shrank.
    static let scrimBottomPadding: CGFloat = 10

    /// Inset from each side of the tile.
    static let scrimHorizontalPadding: CGFloat = 10

    /// Gap between the title and the optional subtitle beneath it.
    static let titleSubtitleSpacing: CGFloat = 2

    /// How far the title may shrink to stay on its one line before it
    /// truncates (issue #353).
    ///
    /// The title is 17 pt semibold and the tile gives it its width less the
    /// two side paddings. "Freedoom Phase 2" is 147.6 pt wide, so it needs a
    /// 168 pt tile; a closed iPhone Duo's are 162 pt and the 360 pt phones'
    /// are 154 pt, where both bundled games read "Freedoom Phas…" and could
    /// not be told apart. Those need 0.96 and 0.91 of full size. 0.85 covers
    /// both with room for a slightly longer name, and at 17 pt it is 14.5 pt
    /// type: still a title. A genuinely long name ("Freedoom Phase 2 +
    /// SCYTHE" is 233 pt) truncates as before, which the view's own comment
    /// accepts.
    static let titleMinimumScaleFactor: CGFloat = 0.85

    /// The ceiling the scrim has to stay under: at most this share of the
    /// tile's height at one title line.
    ///
    /// Not a derived number — a judgement, fixed here so it is arguable in one
    /// place. Nearly half a card spent on one line of text reads as a caption
    /// with art behind it rather than art with a caption on it, which inverts
    /// what spec §5 means by "tiles carry the identity".
    static let maximumScrimShare: CGFloat = 0.40

    /// `.headline`'s line height at the default Dynamic Type size.
    ///
    /// A constant for the same reason `PlayableDetailLayout.defaultCaptionHeight`
    /// is one: the real figure follows whatever text size the reader is in, and
    /// a test that changes answer with a device setting proves nothing. The view
    /// draws real type and lets it grow; this is what the budget is checked
    /// against.
    static let defaultTitleLineHeight: CGFloat = 22

    /// TITLEPIC's stored pixel dimensions — 320 × 200, i.e. 8:5.
    static let titlePicStoredSize = CGSize(width: 320, height: 200)

    /// TITLEPIC's aspect as Doom *displays* it. The engine draws those 320 × 200
    /// pixels into a 4:3 frame — each pixel 1.2× taller than it is wide — which
    /// is why the art looks correct in game and stretched when its stored pixels
    /// are taken at face value. `Theme.tileAspectRatio` is this number.
    static let titlePicDisplayAspectRatio: CGFloat = 4.0 / 3.0

    /// A tile's height at a given width.
    static func tileHeight(width: CGFloat) -> CGFloat {
        max(0, width) / Theme.tileAspectRatio
    }

    /// The floor the viewport's cap on a tile will not go below, for the same
    /// reason `ShelfHeroLayout.minimumArtHeight` is one: a window too short
    /// for this much tile cannot show a game whatever the tile's shape, and a
    /// strip is not art. A tile that is shorter than this at its own shape is
    /// left at that shape.
    static let minimumCappedTileHeight: CGFloat = 120

    /// A tile's height at a given width in a window whose shelf shows
    /// `viewportHeight` without scrolling: its 4:3 shape, unless that is
    /// taller than the window has room for (issue #431).
    ///
    /// A tile's title is drawn along its bottom edge. At an accessibility
    /// text size the grid is one column, so on a closed iPhone Duo held on
    /// its side a tile was 562 pt wide and 421 pt tall in a viewport of about
    /// 360: no scroll position showed a game's art and its name together.
    /// The cap is the viewport less the shelf's inset above and below, so a
    /// tile scrolled to the top of the grid ends above the fold with the same
    /// margin under it as over it. The art gives up a band of its height
    /// instead (`TitleArtView` crops to whatever shape it is handed), as the
    /// Continue hero's does.
    ///
    /// Nothing phone-sized reaches the cap at any text size but that one
    /// window: two columns or more make a tile far shorter than a viewport.
    ///
    /// - Parameter viewportHeight: zero or non-finite means "not measured
    ///   yet", and the tile keeps its shape, as the hero's art does.
    static func tileHeight(width: CGFloat,
                           viewportHeight: CGFloat,
                           contentPadding: CGFloat) -> CGFloat {
        let natural = tileHeight(width: width)
        guard viewportHeight.isFinite, viewportHeight > 0 else { return natural }
        let room = viewportHeight - contentPadding * 2
        return min(natural, max(room, minimumCappedTileHeight))
    }

    /// The shape that goes with the capped height: `Theme.tileAspectRatio`
    /// wherever the cap does not bind, wider where it does. This is what the
    /// shelf hands each tile.
    static func tileAspectRatio(width: CGFloat,
                                viewportHeight: CGFloat,
                                contentPadding: CGFloat) -> CGFloat {
        let height = tileHeight(width: width, viewportHeight: viewportHeight,
                                contentPadding: contentPadding)
        guard width > 0, height > 0 else { return Theme.tileAspectRatio }
        return max(Theme.tileAspectRatio, width / height)
    }

    /// How many lines a tile's title may take (issue #426).
    ///
    /// One, up to the default text size: that is the size the scrim's ceiling
    /// below was set at, and there the title's small shrink
    /// (`titleMinimumScaleFactor`) is enough to keep the bundled games'
    /// names whole. Above it the type grows and a two-column tile does not:
    /// at the largest standard size "Freedoom Phase 1" is 200 pt of title in
    /// a 142 pt line and would need 0.71 of its size, and at the largest
    /// accessibility size 460 pt in 324. Shrinking that far undoes the size
    /// the reader asked for, so the title takes a second line instead and
    /// the scrim grows with it.
    static func titleLineLimit(largerThanDefaultText: Bool) -> Int {
        largerThanDefaultText ? 2 : 1
    }

    /// The narrowest line that holds a title whole on one line, given
    /// `shrunkWidth`: the title's width set in its font at
    /// `titleMinimumScaleFactor` of the font's size, the smallest the one-line
    /// title shrinks to. A point over, because that width is `UIFont`'s
    /// measure and the line is SwiftUI's. Above the default text size a tile
    /// whose line is narrower than this gives the title its second line; one
    /// that is not draws the title exactly as it did before there was a
    /// second line.
    ///
    /// The width at the smaller size, not the full width scaled (issue #458):
    /// type is not drawn in proportion to its size, and at 0.85 of its size a
    /// title is wider than 0.85 of its full width. At
    /// `accessibility-extra-extra-large` "Freedoom Phase 1" is 385.4 pt, so
    /// 327.6 pt scaled, but 328.9 pt set at 40 pt, and SwiftUI drew it whole
    /// only in a line of 329.5 pt or more. The scaled figure declared it fit
    /// in 329, which is an iPhone 17e's landscape tile, and the title was cut
    /// to "Freedoom Phase…" there.
    static func oneLineTitleMinimumWidth(shrunkWidth: CGFloat) -> CGFloat {
        max(0, shrunkWidth).rounded(.up) + 1
    }

    /// The scrim's total height: the paddings above and below, the title's own
    /// line, and the subtitle plus its gap when there is one.
    ///
    /// - Parameters:
    ///   - titleLineHeight: line height of the title's font (`.headline`). One
    ///     line, because `PlayableTileView` limits the title to one.
    ///   - subtitleLineHeight: zero when there is no subtitle, which is every
    ///     tile on the shelf.
    static func scrimHeight(titleLineHeight: CGFloat = defaultTitleLineHeight,
                            subtitleLineHeight: CGFloat = 0) -> CGFloat {
        let subtitle = subtitleLineHeight > 0 ? subtitleLineHeight + titleSubtitleSpacing : 0
        return scrimTopPadding + titleLineHeight + subtitle + scrimBottomPadding
    }

    /// What share of a tile of this width the scrim covers.
    static func scrimShare(tileWidth: CGFloat,
                           titleLineHeight: CGFloat = defaultTitleLineHeight,
                           subtitleLineHeight: CGFloat = 0) -> CGFloat {
        let height = tileHeight(width: tileWidth)
        guard height > 0 else { return 0 }
        return scrimHeight(titleLineHeight: titleLineHeight,
                           subtitleLineHeight: subtitleLineHeight) / height
    }

    /// The fraction of a source image's **width** that stays visible when it is
    /// scaled to fill a frame of this aspect and clipped to it — SwiftUI's
    /// `scaledToFill`, as arithmetic.
    ///
    /// Filling scales by `max(frameW / srcW, frameH / srcH)`, so a source wider
    /// than its frame overflows sideways and is cropped there, and the fraction
    /// left is the ratio of the two aspects. A source narrower than its frame
    /// keeps all of its width and gives up height instead.
    static func visibleWidthFraction(sourceAspectRatio: CGFloat,
                                     frameAspectRatio: CGFloat) -> CGFloat {
        guard sourceAspectRatio > 0, frameAspectRatio > 0 else { return 0 }
        return min(1, frameAspectRatio / sourceAspectRatio)
    }

    /// The same for the source's **height**, which is the axis that gives when
    /// the frame is wider than the source.
    static func visibleHeightFraction(sourceAspectRatio: CGFloat,
                                      frameAspectRatio: CGFloat) -> CGFloat {
        guard sourceAspectRatio > 0, frameAspectRatio > 0 else { return 0 }
        return min(1, sourceAspectRatio / frameAspectRatio)
    }
}
