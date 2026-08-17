import CoreGraphics

/// Pure geometry for the detail page's header art: viewport in, art height
/// out. Same shape as `ShelfHeroLayout`, against the same hazard, and tested
/// the same way — over supplied bounds rather than through a rendered screen.
///
/// ## Why the detail page needs a height at all
///
/// `PlayableDetailView`'s header drew its art at `Theme.tileAspectRatio`, which
/// is a *tile* shape: portrait, because tiles are portrait. On the full width
/// of a sheet that ratio is enormous — 370 pt of row width came out 481 pt
/// tall on an iPhone 17 Pro, 60% of the sheet — and the Contents section, the
/// Controls picker and the saves list all landed below the fold.
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
    /// A `Form` row's own vertical padding, above and below its content.
    /// Measured from the rendered hierarchy: a `.title2` line (26.3 pt) sat in
    /// a 56.3 pt row.
    static let rowPadding: CGFloat = 30

    /// A `Form` row's inset from each edge of the form. Measured from the
    /// rendered hierarchy: a 402 pt form held its rows at x = 16, width 370.
    static let rowHorizontalInset: CGFloat = 16

    /// A `.large` bordered button's padding around its label, on top of the
    /// row padding it also sits in. Measured the same way: a `.body` line
    /// (20.3 pt) in an 80.3 pt row.
    static let largeButtonPadding: CGFloat = 30

    /// The gap a `Form` leaves between the last row of one section and the
    /// header of the next.
    static let sectionGap: CGFloat = 18

    /// How much of the form below the header has to stay above the fold.
    ///
    /// Sized against the tallest first section any item shows: a preset's
    /// Contents — a header, four `LabeledContent` rows, and the Edit button
    /// that ends it — which measures about 300 pt at the default Dynamic Type
    /// size. Reserving the whole of it is deliberate rather than generous:
    /// Edit is the *last* row, and a lazy `Form` that stops short of it leaves
    /// the detail page's only route to the editor uninstantiated.
    static let minimumControlsPeek: CGFloat = 300

    /// The floor the cap will not go below. A viewport short enough to hit
    /// this cannot show art, header and controls at once however the space is
    /// divided, so the controls go back to being reached by scrolling rather
    /// than the art collapsing into a strip too thin to read as art.
    static let minimumArtHeight: CGFloat = 96

    /// The header block below the art at the default Dynamic Type size: a
    /// title row over one primary button. `PlayableDetailView` measures the
    /// real one from `UIFont`, so accessibility sizes reserve what they
    /// actually need; this is the value tests and previews use.
    static let defaultCaptionHeight: CGFloat = captionHeight(titleLineHeight: 26.3,
                                                             buttonLineHeight: 20.3,
                                                             primaryButtonCount: 1)

    /// Height of everything the header draws *below* the art: the item's title,
    /// then one primary button (Play) or two (Continue and New Game).
    ///
    /// - Parameters:
    ///   - titleLineHeight: line height of the title's font (`.title2`).
    ///   - buttonLineHeight: line height of a button label's font (`.body`).
    ///   - primaryButtonCount: 1 with no resumable save, 2 with one.
    static func captionHeight(titleLineHeight: CGFloat,
                              buttonLineHeight: CGFloat,
                              primaryButtonCount: Int) -> CGFloat {
        let title = titleLineHeight + rowPadding
        let button = buttonLineHeight + largeButtonPadding + rowPadding
        return title + CGFloat(max(0, primaryButtonCount)) * button + sectionGap
    }

    /// Height for the detail header's art.
    ///
    /// - Parameters:
    ///   - contentWidth: width the art is drawn at, i.e. the form's width less
    ///     its row insets.
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
