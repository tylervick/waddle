import CoreGraphics

/// Pure geometry for the game page's header art: viewport in, art height
/// out. Same shape as `ShelfHeroLayout`, against the same hazard, and tested
/// the same way — over supplied bounds rather than through a rendered screen.
///
/// ## Why the game page needs a height at all
///
/// The game page's predecessor drew its header art at `Theme.tileAspectRatio`,
/// which is a *tile* shape: portrait, because tiles are portrait. On the full
/// width of a sheet that ratio is enormous — 370 pt of row width came out 481
/// pt tall on an iPhone 17 Pro, 60% of the sheet — and the Contents section,
/// the Controls picker and the saves list all landed below the fold.
///
/// A SwiftUI `Form` is a lazy collection view, so those rows were not merely
/// out of sight: they were never instantiated, and so were absent from the
/// accessibility hierarchy entirely. That is what made the bug read as "the
/// detail sheet never opened" when it had in fact opened every time — the only
/// part of it anything could see was the header.
///
/// The art now takes TITLEPIC's own landscape shape (`Theme.heroAspectRatio`,
/// the same one the Continue hero uses on the other full-width surface) and
/// shrinks below it only on viewports too short to hold it plus the controls
/// underneath.
enum PlayableDetailLayout {
    /// A `Form`'s inset from each edge of the page to its rows, measured from
    /// the rendered hierarchy: a 402 pt form holds its rows at x = 16, width
    /// 370. The hero row adds no inset of its own (design-system spec §4), so
    /// its art and caption sit flush with the cards below, the way the
    /// shelf's hero shares an edge with its grid, and the blurred backdrop
    /// is what bleeds.
    static let rowHorizontalInset: CGFloat = 16

    /// Above the art, inside the hero row.
    static let captionTopPadding: CGFloat = 8

    /// Between the art, the title and the button row, and between stacked
    /// buttons.
    static let captionSpacing: CGFloat = 12

    /// A `WaddleButtonStyle`'s padding above and below its label; the button
    /// is the taller of the label plus this and `Theme.minimumTapTarget`.
    /// Named here so the budget and the style cannot disagree.
    static let buttonVerticalPadding: CGFloat = Theme.buttonVerticalPadding

    /// Below the button row, before the first section header.
    static let captionBottomPadding: CGFloat = 16

    /// How much of the form below the header has to stay above the fold.
    ///
    /// Sized against the tallest first section any item shows: a game's
    /// Contents — a header, four `LabeledContent` rows, and the Edit button
    /// that ends it — which measures about 300 pt at the default Dynamic Type
    /// size. Reserving the whole of it is deliberate rather than generous:
    /// Edit is the *last* row, and a lazy `Form` that stops short of it leaves
    /// the game page's only route to editing uninstantiated.
    static let minimumControlsPeek: CGFloat = 300

    /// The floor the cap will not go below. A viewport short enough to hit
    /// this cannot show art, header and controls at once however the space is
    /// divided, so the controls go back to being reached by scrolling rather
    /// than the art collapsing into a strip too thin to read as art.
    static let minimumArtHeight: CGFloat = 96

    /// The header block below the art at the default Dynamic Type size: a
    /// title row over one primary button. `GamePageView` measures the
    /// real one from `UIFont`, so accessibility sizes reserve what they
    /// actually need; this is the value tests and previews use.
    static let defaultCaptionHeight: CGFloat = captionHeight(titleLineHeight: 26.3,
                                                             buttonLineHeight: 20.3,
                                                             primaryButtonCount: 1)

    /// Height of everything the header draws *below* the art: the gap under
    /// the art, the item's title, the gap under that, then one primary button
    /// (Play) or two (Continue and New Game) with a gap between them.
    ///
    /// Charged per button, as if stacked, even though at ordinary text sizes
    /// `ViewThatFits` puts two side by side: the stacked case is the one that
    /// happens at accessibility sizes, where the budget is tightest, and in
    /// portrait the art is natural-bound anyway so the over-reserve costs
    /// nothing visible.
    ///
    /// - Parameters:
    ///   - titleLineHeight: line height of the title's font (`.title2`).
    ///   - buttonLineHeight: line height of a button label's font (`.body`).
    ///   - primaryButtonCount: 1 with no resumable save, 2 with one.
    static func captionHeight(titleLineHeight: CGFloat,
                              buttonLineHeight: CGFloat,
                              primaryButtonCount: Int) -> CGFloat {
        let buttons = CGFloat(max(0, primaryButtonCount))
        let button = max(Theme.minimumTapTarget, buttonLineHeight + buttonVerticalPadding * 2)
        // Two gaps always -- art to title, title to actions -- plus one more
        // between each extra stacked button (review of PR #305 caught the
        // formula counting only the second; the rendered cell is 12 pt taller
        // than that formula said).
        return captionTopPadding
            + titleLineHeight
            + captionSpacing * (2 + max(0, buttons - 1))
            + buttons * button
            + captionBottomPadding
    }

    // MARK: Side by side (design-system spec §8)

    /// How the hero row arranges its art and caption.
    enum HeroArrangement: Equatable {
        /// Art above the title and actions: portrait, and before measurement.
        case stacked
        /// Art beside the title and actions: a page wider than it is tall.
        case sideBySide
    }

    /// Stacked until the viewport is measured; side by side once the page is
    /// wider than it is tall. Stacking on a short, wide page is what pinned
    /// the art to its 96 pt floor on every landscape phone: the caption and
    /// the controls' peek left nothing for it. Beside the caption, the art
    /// spends width, which a landscape page has to spare.
    static func arrangement(contentWidth: CGFloat, viewportHeight: CGFloat) -> HeroArrangement {
        guard viewportHeight.isFinite, viewportHeight > 0 else { return .stacked }
        return contentWidth > viewportHeight ? .sideBySide : .stacked
    }

    /// At most this much of the row's width goes to the art when it sits
    /// beside the caption; the title and two buttons need the rest.
    static let sideBySideArtWidthFraction: CGFloat = 0.5

    /// What must stay visible below a side-by-side hero: one tap target of
    /// the first section, so the page reads as scrollable. The stacked
    /// `minimumControlsPeek` (300) is unreachable on a landscape phone at all
    /// -- that is why stacking there fell to the floor.
    static let sideBySideMinimumPeek: CGFloat = Theme.minimumTapTarget

    /// Height for the art beside the caption: TITLEPIC's shape at up to half
    /// the row's width, shrunk so one tap target of the next section still
    /// shows, and never below `minimumArtHeight`.
    static func sideBySideArtHeight(contentWidth: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let widest = (max(0, contentWidth) - captionSpacing) * sideBySideArtWidthFraction
        let natural = widest / Theme.heroAspectRatio
        guard viewportHeight.isFinite, viewportHeight > 0 else { return natural }
        let room = viewportHeight - captionTopPadding - captionBottomPadding - sideBySideMinimumPeek
        return min(natural, max(room, minimumArtHeight))
    }

    /// The width that goes with `sideBySideArtHeight`: the art keeps its shape.
    static func sideBySideArtWidth(contentWidth: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        sideBySideArtHeight(contentWidth: contentWidth, viewportHeight: viewportHeight) * Theme.heroAspectRatio
    }

    /// The caption column beside the art: the title, a gap, then the buttons
    /// stacked -- the column is at most half the row, so `ViewThatFits` falls
    /// to the stacked buttons there more often than it does in portrait, and
    /// the budget assumes it has.
    static func sideBySideCaptionHeight(titleLineHeight: CGFloat,
                                        buttonLineHeight: CGFloat,
                                        primaryButtonCount: Int) -> CGFloat {
        let buttons = CGFloat(max(0, primaryButtonCount))
        let button = max(Theme.minimumTapTarget, buttonLineHeight + buttonVerticalPadding * 2)
        return titleLineHeight + captionSpacing + buttons * button + max(0, buttons - 1) * captionSpacing
    }

    /// The whole hero row, side by side: its paddings around the taller of
    /// the art and the caption. The art is the only part the budget can
    /// shrink; the caption is text at the reader's Dynamic Type size and is
    /// not negotiable. So when the caption alone is taller than the room,
    /// the row is taller than the room and the first section is reached by
    /// scrolling -- the same answer the stacked layout gives when its floor
    /// binds, and the honest one: a shorter art would not have helped.
    static func sideBySideRowHeight(contentWidth: CGFloat,
                                    viewportHeight: CGFloat,
                                    captionHeight: CGFloat) -> CGFloat {
        let art = sideBySideArtHeight(contentWidth: contentWidth, viewportHeight: viewportHeight)
        return captionTopPadding + max(art, captionHeight) + captionBottomPadding
    }

    /// Height for the detail header's art when stacked above the caption.
    ///
    /// - Parameters:
    ///   - contentWidth: width the art is drawn at, i.e. the page's width less
    ///     `rowHorizontalInset` on each side.
    ///   - viewportHeight: height visible without scrolling, i.e. the form's
    ///     height less its top and bottom safe-area insets. Zero or non-finite
    ///     means "not measured yet", and the art keeps its natural height; a
    ///     first frame with an unmeasured viewport must not flash art clamped
    ///     to `minimumArtHeight`.
    ///   - captionHeight: height of the title-and-buttons block below the art,
    ///     which shares the same viewport and so comes out of the same budget.
    static func artHeight(contentWidth: CGFloat,
                          viewportHeight: CGFloat,
                          captionHeight: CGFloat = defaultCaptionHeight) -> CGFloat {
        let natural = max(0, contentWidth) / Theme.heroAspectRatio
        guard viewportHeight.isFinite, viewportHeight > 0 else { return natural }
        let room = viewportHeight - captionHeight - minimumControlsPeek
        return min(natural, max(room, minimumArtHeight))
    }
}
