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

    // MARK: - The welcome card

    // The first-launch welcome card occupies this same hero zone -- spec §4 has
    // the two as alternatives, never both at once -- so it is bounded against
    // the same viewport, by the same `sectionSpacing` and `minimumGridPeek`,
    // for the same reason: a `LazyVGrid` never instantiates off-screen cells,
    // so a top zone that fills the viewport takes the whole library out of the
    // accessibility hierarchy, not merely out of sight.
    //
    // Why this is not `artHeight`: the hero has one element whose height is
    // free -- the art, sized by an aspect ratio off the width -- and a caption
    // whose height is reserved and never compressed. The card has no such
    // element; name, line and button are all intrinsic, and there is no ratio
    // to divide. So the bound here is a ceiling on the whole card rather than a
    // height for one part of it, and the two share their arithmetic rather than
    // one calling the other.
    //
    // At the default Dynamic Type size this ceiling is inert: the card measures
    // 165.3 pt against roughly 231 pt of room on a landscape phone, and more
    // everywhere else. It binds at accessibility sizes, where those same three
    // rows come to 319.4 pt and would otherwise leave 31.6 pt of grid band --
    // measured, both of them, by the tests in ShelfHeroLayoutTests.

    /// The floor the ceiling will not go below, holding the card's three rows —
    /// name, line and button — at the default Dynamic Type size with its own
    /// padding. A viewport too short to grant even this cannot show the card
    /// and a tile row at once however the space is divided, so the card keeps
    /// its rows and the grid goes back to being reached by scrolling, exactly
    /// as `minimumArtHeight` decides for the hero.
    ///
    /// Measured, not chosen: the default-size card comes to 165.3 pt with its
    /// line unwrapped and 183.2 pt with that line on two, which is the shape it
    /// takes at the narrow widths where a viewport this short actually occurs.
    /// The floor is the wrapped figure, so it holds the card that a cramped
    /// screen really draws rather than the roomiest one.
    static let minimumWelcomeCardHeight: CGFloat = 184

    /// The card's own inset around its content, and the gaps between its three
    /// rows. `ShelfView` draws with these, so the height reasoned about here
    /// and the height drawn cannot drift apart — the same contract
    /// `sectionSpacing` holds for the gap below.
    static let welcomeCardPadding: CGFloat = 16
    static let welcomeCardSpacing: CGFloat = 12

    /// What the card's three rows need, measured rather than assumed:
    /// `ShelfView` reads the first two from `UIFont`, which already carries the
    /// reader's Dynamic Type setting, for the same reason `heroCaptionHeight`
    /// does.
    ///
    /// - Parameters:
    ///   - nameLineHeight: line height of the app name's font (`.title`).
    ///   - bodyHeight: height of the explanatory line, which wraps — one line
    ///     on a wide viewport, more on a narrow one or at a large type size.
    ///   - buttonHeight: height of the Add Your Games button, whose label
    ///     already claims `Theme.minimumTapTarget` at minimum.
    static func welcomeCardNaturalHeight(nameLineHeight: CGFloat,
                                         bodyHeight: CGFloat,
                                         buttonHeight: CGFloat) -> CGFloat {
        welcomeCardPadding * 2
            + nameLineHeight + welcomeCardSpacing
            + bodyHeight + welcomeCardSpacing
            + buttonHeight
    }

    /// The tallest the welcome card may be drawn before the grid's first row
    /// stops being reachable.
    ///
    /// Applied as a *maximum* rather than an exact height on purpose: the card
    /// is intrinsic content, and a height forced on it from outside would
    /// squeeze rows whenever the arithmetic above misjudged a font by a point.
    /// A ceiling can only ever take space the card was not entitled to.
    ///
    /// - Parameter viewportHeight: height visible without scrolling. Zero or
    ///   non-finite means "not measured yet" and imposes no ceiling at all; a
    ///   first frame with an unmeasured viewport must not flash a card clamped
    ///   to its floor.
    /// - Returns: the ceiling, or `nil` for no ceiling. Deliberately optional
    ///   rather than `.infinity`: `.frame(maxHeight:)` reads `nil` as
    ///   "unconstrained" but reads `.infinity` as *grow to fill the offer*,
    ///   which on a bounded proposal would stretch the card down the screen —
    ///   the very thing this type exists to prevent.
    static func welcomeCardMaxHeight(viewportHeight: CGFloat) -> CGFloat? {
        guard viewportHeight.isFinite, viewportHeight > 0 else { return nil }
        let room = viewportHeight - sectionSpacing - minimumGridPeek
        return max(room, minimumWelcomeCardHeight)
    }

    /// The height the card actually draws at: what it needs, or the ceiling,
    /// whichever is smaller. This is what the tests assert over — the ceiling
    /// alone says nothing about a card that was never going to reach it.
    static func welcomeCardHeight(naturalHeight: CGFloat,
                                  viewportHeight: CGFloat) -> CGFloat {
        guard let ceiling = welcomeCardMaxHeight(viewportHeight: viewportHeight) else {
            return naturalHeight
        }
        return min(naturalHeight, ceiling)
    }
}
