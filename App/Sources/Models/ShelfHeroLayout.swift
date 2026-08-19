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

    /// The welcome card's height at the default Dynamic Type size, measured on
    /// a 408 pt content width (iPhone 17 Pro, the destination `ui-tests.yml`
    /// runs): app name, a two-line description, the 44 pt button, the two 12 pt
    /// gaps between them, and 16 pt of padding top and bottom.
    ///
    /// A measured constant rather than a computed one, and deliberately so:
    /// what is needed here is a *decision* taken before the card is laid out,
    /// and measuring the real card to decide how to build it is a layout
    /// feedback loop. It is used only to compare against the budget below, so
    /// being a few points off moves the device size at which the card goes
    /// compact -- it cannot produce a card that does not fit.
    static let welcomeCardFullHeight: CGFloat = 184

    /// The same card without its description line. This is what the card
    /// costs once `welcomeCardShowsDescription` says no.
    static let welcomeCardCompactHeight: CGFloat = 138

    /// The width one grid column gets, given the width available to the grid
    /// and the adaptive minimum `ShelfView` asks for. Mirrors what
    /// `GridItem(.adaptive(minimum:spacing:))` resolves to: as many columns as
    /// fit at that minimum, sharing the width left after the gaps between them.
    ///
    /// The shelf needs this because the first tile row's *height* is what the
    /// hero zone has to leave room for, and that height follows from the
    /// column width via `Theme.tileAspectRatio`.
    static func gridColumnWidth(contentWidth: CGFloat,
                                minimum: CGFloat,
                                spacing: CGFloat) -> CGFloat {
        guard contentWidth > 0, minimum > 0 else { return 0 }
        let columns = max(1, (contentWidth + spacing) / (minimum + spacing))
        let count = max(1, columns.rounded(.down))
        return (contentWidth - spacing * (count - 1)) / count
    }

    /// Whether the welcome card can afford its description line.
    ///
    /// ## Why the welcome card needs a budget at all
    ///
    /// The Continue hero has had one since `artHeight` above: it is capped so
    /// the first tile row stays reachable. The welcome card was added to the
    /// same zone (spec §4) without one, and on the reference phone the numbers
    /// do not work out -- a 408 pt content width resolves to a single 544 pt
    /// tile, and 184 pt of card above it puts the row's bottom past the fold.
    /// The tile is still on screen and still in the accessibility hierarchy, so
    /// `minimumGridPeek` is satisfied and reports nothing wrong; what is lost is
    /// the row being *tappable*, which is what that peek exists to protect.
    /// `EngineSmokeTests` caught it as a tap that synthesized cleanly and
    /// activated nothing.
    ///
    /// Dropping the description keeps the two elements spec §4 leads with --
    /// the app name and the primary Add Your Games button -- and buys back the
    /// 46 pt that makes the row fit.
    ///
    /// - Parameters:
    ///   - viewportHeight: height visible without scrolling. Zero or
    ///     non-finite means "not measured yet"; the card keeps its full form
    ///     rather than flashing compact on the first frame.
    ///   - contentWidth: width available to the grid, i.e. the viewport less
    ///     safe-area and padding.
    ///   - tileMinimumWidth: the adaptive minimum the grid was built with.
    ///   - contentPadding: the padding around the whole scrolling column,
    ///     which the first row has to clear at the bottom as well as the top.
    ///   - gridSpacing: the gap between grid columns.
    static func welcomeCardShowsDescription(viewportHeight: CGFloat,
                                            contentWidth: CGFloat,
                                            tileMinimumWidth: CGFloat,
                                            contentPadding: CGFloat,
                                            gridSpacing: CGFloat) -> Bool {
        guard viewportHeight.isFinite, viewportHeight > 0 else { return true }
        let tileRowHeight = gridColumnWidth(contentWidth: contentWidth,
                                            minimum: tileMinimumWidth,
                                            spacing: gridSpacing) / Theme.tileAspectRatio
        // Both paddings: the row has to end above the fold, not merely start
        // above it, and the column's bottom padding sits below the row.
        let budget = viewportHeight - contentPadding * 2 - sectionSpacing - tileRowHeight
        return budget >= welcomeCardFullHeight
    }

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
