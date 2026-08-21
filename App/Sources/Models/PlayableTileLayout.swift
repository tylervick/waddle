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
