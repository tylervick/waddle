import CoreGraphics

/// Pure geometry for the shelf's Continue hero: viewport in, art height out.
/// No views, no environment — same shape as `TouchOverlayLayout`, and tested
/// the same way, over supplied bounds rather than through a rendered screen.
///
/// ## Why the hero needs a height at all
///
/// The hero used to be sized by its aspect ratio alone: full width, and
/// whatever height ~1.6:1 demanded of that width. That is fine when the
/// viewport is tall relative to its width and wrong when it is not. On a
/// landscape phone (≈956×440 pt) the art alone came out around 500 pt tall in a
/// viewport of roughly 375 pt, so it filled the screen and pushed the hero's
/// own title and "Continue" caption — and every grid tile — below the fold. A
/// `LazyVGrid` never instantiates off-screen cells, so the whole library was
/// also absent from the accessibility hierarchy while the hero was present.
///
/// The fix is a cap, not a demotion (spec §5 still has the hero leading the
/// screen): the art keeps its natural full-width height wherever that fits,
/// and only shrinks on viewports too short to hold it plus the rest of the
/// screen's first impression.
enum ShelfHeroLayout {
    /// Vertical gap between the hero and the grid below it. `ShelfView`'s own
    /// `VStack` reads this, so the space reserved here and the space actually
    /// drawn cannot drift apart.
    static let sectionSpacing: CGFloat = 24

    /// How much of the first tile row has to stay above the fold. More than
    /// double spec §5's 44 pt minimum target, which is the bar it has to
    /// clear: the first row must be recognizable *and* tappable without
    /// scrolling, and — because a `LazyVGrid` omits off-screen cells — present
    /// in the accessibility hierarchy at all.
    static let minimumGridPeek: CGFloat = 120

    /// The hero's caption block at the default Dynamic Type size: the title
    /// (`.title2`) over the Continue line (`.subheadline`), plus the two 6 pt
    /// gaps of the stack holding them. `ShelfView` measures the real one from
    /// `UIFont` so accessibility sizes reserve what they actually need; this
    /// is the value tests and previews use.
    static let defaultCaptionHeight: CGFloat = 60

    /// The floor the cap will not go below. A viewport short enough to hit
    /// this cannot show the hero, its caption and a tile row at once no matter
    /// how the space is divided, so the hero keeps its priority and the grid
    /// goes back to being reached by scrolling — rather than the hero
    /// collapsing into a strip too thin to read as art.
    static let minimumArtHeight: CGFloat = 96

    /// Height for the hero's art.
    ///
    /// - Parameters:
    ///   - contentWidth: width available to the hero, i.e. the viewport's
    ///     width less safe-area and padding — the width the art is drawn at.
    ///   - viewportHeight: height visible without scrolling, i.e. the scroll
    ///     view's height less its top and bottom safe-area insets. Zero or
    ///     non-finite means "not measured yet", and the art keeps its natural
    ///     height; a first frame with an unmeasured viewport must not flash a
    ///     hero clamped to `minimumArtHeight`.
    ///   - captionHeight: height of the title-plus-Continue block below the
    ///     art, which shares the same viewport and so comes out of the same
    ///     budget.
    static func artHeight(contentWidth: CGFloat,
                          viewportHeight: CGFloat,
                          captionHeight: CGFloat = defaultCaptionHeight) -> CGFloat {
        let natural = max(0, contentWidth) / Theme.heroAspectRatio
        guard viewportHeight.isFinite, viewportHeight > 0 else { return natural }
        let room = viewportHeight - captionHeight - sectionSpacing - minimumGridPeek
        return min(natural, max(room, minimumArtHeight))
    }
}
