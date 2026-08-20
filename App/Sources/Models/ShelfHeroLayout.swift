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

    /// The welcome card's own metrics: 16 pt of padding all round, 12 pt
    /// between its rows. Constants because they are literals in `ShelfView`'s
    /// card and do not scale with Dynamic Type; everything that *does* scale is
    /// measured and passed into `welcomeCardHeight` below.
    static let welcomeCardPadding: CGFloat = 16
    static let welcomeCardRowSpacing: CGFloat = 12

    /// The card's height, from the three rows whose heights follow the
    /// reader's text size.
    ///
    /// Measured rather than assumed, for the same reason `artHeight` takes a
    /// `captionHeight` instead of hard-coding one: the app name, the
    /// description and the button label all grow at accessibility sizes, and a
    /// budget written against the default size would clear a card half again
    /// as tall and put the first tile row right back below the fold.
    ///
    /// - Parameter descriptionHeight: zero for the compact form — the card
    ///   without its description line — which also drops one row gap.
    static func welcomeCardHeight(titleHeight: CGFloat,
                                  descriptionHeight: CGFloat,
                                  buttonHeight: CGFloat) -> CGFloat {
        let rows = descriptionHeight > 0
            ? [titleHeight, descriptionHeight, buttonHeight]
            : [titleHeight, buttonHeight]
        return welcomeCardPadding * 2
            + rows.reduce(0, +)
            + welcomeCardRowSpacing * CGFloat(rows.count - 1)
    }

    /// How many columns the adaptive grid resolves to, given the width
    /// available to it and the minimum `ShelfView` asks for. Mirrors
    /// `GridItem(.adaptive(minimum:spacing:))`: as many columns of at least
    /// that width as fit, never fewer than one.
    ///
    /// Split out of `gridColumnWidth` below so the count can be asserted
    /// directly. It is the count, not the width, that the shelf's whole
    /// above-the-fold problem turns on — one column makes the first row 3:4 of
    /// the entire content width — and a test that could only infer it from a
    /// width would not say so.
    static func gridColumnCount(contentWidth: CGFloat,
                                minimum: CGFloat,
                                spacing: CGFloat) -> Int {
        guard contentWidth > 0, minimum > 0 else { return 1 }
        return max(1, Int(((contentWidth + spacing) / (minimum + spacing)).rounded(.down)))
    }

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
        let count = CGFloat(gridColumnCount(contentWidth: contentWidth,
                                            minimum: minimum,
                                            spacing: spacing))
        return (contentWidth - spacing * (count - 1)) / count
    }

    /// How far above the fold the first tile row's bottom edge has to land.
    ///
    /// `heroZoneBudget` below is a *measurement* — how much room the zone has.
    /// This is the *requirement* placed on it, and the two are deliberately
    /// separate constants rather than one number that means both.
    ///
    /// ## Why a bare fit is not enough
    ///
    /// The budget used to be spent down to zero: a hero zone was accepted as
    /// fitting when the row's bottom landed *exactly* on the fold. On the
    /// geometry #204 measured that left about 16 pt of slack, and 16 pt was
    /// not enough — `EngineSmokeTests.testEngineBootQuitRelaunchCycle`
    /// passed one attempt and failed the next on the same commit. A margin that small is
    /// inside this type's own modelling error, so a layout that "fits" by it
    /// is really a coin flip.
    ///
    /// ## Where the number comes from
    ///
    /// 44 pt, spec §5's minimum tap target, reached from two directions:
    ///
    /// - The row has to be *tappable* without scrolling, not merely visible.
    ///   Requiring its bottom edge to clear the fold by a full tap target
    ///   means the row is never reduced to a sliver that happens to be on
    ///   screen — which is exactly the state the flaky tap was hitting.
    /// - It has to absorb the error in `welcomeCardHeight`, which sums
    ///   `UIFont` line heights while SwiftUI lays out the real card. The
    ///   largest single thing that estimate can miss is one unmodelled
    ///   `.subheadline` line of the description (≈20 pt at the default size)
    ///   plus the button style's own vertical padding (≈14 pt). 44 pt covers
    ///   both at once, and is nearly three times the 16 pt that demonstrably
    ///   flaked.
    static let minimumFoldClearance: CGFloat = Theme.minimumTapTarget

    /// How much vertical room the hero zone has before the first tile row
    /// stops fitting above the fold. Both content paddings count: the row has
    /// to *end* above the fold, not merely start above it.
    ///
    /// This is the room available, not the room the zone may spend — a zone
    /// is only accepted if it leaves `minimumFoldClearance` of this unused.
    static func heroZoneBudget(viewportHeight: CGFloat,
                               contentWidth: CGFloat,
                               tileMinimumWidth: CGFloat,
                               contentPadding: CGFloat,
                               gridSpacing: CGFloat) -> CGFloat {
        let tileRowHeight = gridColumnWidth(contentWidth: contentWidth,
                                            minimum: tileMinimumWidth,
                                            spacing: gridSpacing) / Theme.tileAspectRatio
        return viewportHeight - contentPadding * 2 - sectionSpacing - tileRowHeight
    }

    /// Whether the welcome card can afford its description line.
    ///
    /// ## Why the welcome card needs a budget at all
    ///
    /// The Continue hero has had one since `artHeight` above: it is capped so
    /// the first tile row stays reachable. The welcome card was added to the
    /// same zone (spec §4) without one, and the numbers did not work out: a
    /// 200 pt adaptive minimum resolved to a single column on *every* iPhone,
    /// making the first row 3:4 of the whole content width — 544 pt on the
    /// widest phone, at 440 pt — and 184 pt of card above that put the row's
    /// bottom past the fold. The tile is still on screen and still in the
    /// accessibility hierarchy, so `minimumGridPeek` is satisfied and reports
    /// nothing wrong; what is lost is the row being *tappable*, which is what
    /// that peek exists to protect.
    /// `EngineSmokeTests` caught it as a tap that synthesized cleanly and
    /// activated nothing.
    ///
    /// Dropping the description keeps the two elements spec §4 leads with —
    /// the app name and the primary **Add Your Games** button.
    ///
    /// ## Where this stops
    ///
    /// The compact card is the smallest this zone gets: there is no third,
    /// smaller form, so a viewport that cannot hold even that leaves the grid
    /// to be reached by scrolling. That is the same floor `minimumArtHeight`
    /// draws for the hero, and it is reached the same way — an accessibility
    /// text size on a short viewport, where a 320 pt adaptive minimum makes the
    /// tile row taller at the same time as the card. Dropping the description
    /// is still the right move there; it just is not sufficient on its own.
    ///
    /// - Parameters:
    ///   - viewportHeight: height visible without scrolling. Zero or
    ///     non-finite means "not measured yet"; the card keeps its full form
    ///     rather than flashing compact on the first frame.
    ///   - contentWidth: width available to the grid, i.e. the viewport less
    ///     safe-area and padding.
    ///   - tileMinimumWidth: the adaptive minimum the grid was built with,
    ///     which is itself Dynamic Type-dependent.
    ///   - contentPadding: the padding around the whole scrolling column.
    ///   - gridSpacing: the gap between grid columns.
    ///   - fullCardHeight: the card *with* its description, at the reader's
    ///     current text size — `welcomeCardHeight` above.
    static func welcomeCardShowsDescription(viewportHeight: CGFloat,
                                            contentWidth: CGFloat,
                                            tileMinimumWidth: CGFloat,
                                            contentPadding: CGFloat,
                                            gridSpacing: CGFloat,
                                            fullCardHeight: CGFloat) -> Bool {
        guard viewportHeight.isFinite, viewportHeight > 0 else { return true }
        let budget = heroZoneBudget(viewportHeight: viewportHeight,
                                    contentWidth: contentWidth,
                                    tileMinimumWidth: tileMinimumWidth,
                                    contentPadding: contentPadding,
                                    gridSpacing: gridSpacing)
        // `+ minimumFoldClearance`, not a bare `>=`: a card that spends the
        // budget exactly leaves the tile row ending on the fold, which is the
        // state that made the tap flaky rather than the state that fixed it.
        return budget >= fullCardHeight + minimumFoldClearance
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
