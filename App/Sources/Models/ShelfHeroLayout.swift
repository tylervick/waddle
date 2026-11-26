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
    ///
    /// 32, not the grid's own gap: the 2026-08-21 design pass found the whole
    /// screen sitting on one uniform 16 pt beat (outer padding = grid gap =
    /// card padding), which is what made the shelf read as unspaced even
    /// though every gap was present. The zone break is the largest interval
    /// in that rhythm on purpose.
    static let sectionSpacing: CGFloat = 32

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

    // MARK: Compact height (design-system spec §9)

    /// How the hero zone arranges itself. Stacked -- art over caption, tagline
    /// over button -- everywhere the viewport is tall enough to hold a hero
    /// and a tile row; side by side where it is not.
    enum Arrangement: Equatable {
        case stacked
        case sideBySide
    }

    /// `compactHeight` is UIKit's compact vertical size class: a landscape
    /// phone, and nothing else. A landscape iPad is wider than tall too, but
    /// has 900-odd points of height and keeps the stacked, dominant hero its
    /// tests record as a decision. On a landscape phone the stacked model
    /// was on its 96 pt floor at the *default* text size once the chrome was
    /// measured honestly (2026-10-02), so beside the caption is the only
    /// arrangement that leaves both the art and a tappable tile row.
    static func arrangement(compactHeight: Bool) -> Arrangement {
        compactHeight ? .sideBySide : .stacked
    }

    /// Below this share of the row's width, stacked art is a banner it cannot
    /// fill: the height cap has shrunk it, its 1.6:1 shape has shrunk its
    /// width with it, and the rest of the row is a blurred fill.
    ///
    /// 0.7 because the two cases it has to tell apart sit well to either side
    /// of it. An open iPhone Duo's capped art fills 58% of the row. A 13-inch
    /// iPad in landscape, whose stacked hero `ShelfHeroLayoutTests` records as
    /// a decision ("capped but still dominant"), fills 78%.
    static let minimumStackedArtFill: CGFloat = 0.7

    /// The hero's arrangement for the window it is actually in (issue #371).
    ///
    /// Compact height is side by side, as above. So is a wide window whose
    /// stacked art would be a pillarboxed banner: `stackedArtHeight` is what
    /// `artHeight` returns there, and if that much art, at its own shape,
    /// covers less than `minimumStackedArtFill` of the row, the row is better
    /// spent putting the art beside its caption. An open iPhone Duo is the
    /// case this exists for: 835 pt of row, 302 pt of art height, 483 pt of
    /// art.
    ///
    /// Only ever on a wide window (`Theme.wideGridContentWidth`). A phone in
    /// portrait fills its row whatever the cap does to it, and must not flip
    /// to a cramped side-by-side because a small viewport shrank the art.
    static func arrangement(compactHeight: Bool,
                            contentWidth: CGFloat,
                            stackedArtHeight: CGFloat) -> Arrangement {
        if compactHeight { return .sideBySide }
        guard contentWidth >= Theme.wideGridContentWidth else { return .stacked }
        let fill = stackedArtHeight * Theme.heroAspectRatio / contentWidth
        return fill < minimumStackedArtFill ? .sideBySide : .stacked
    }

    /// The zone break, by height class: the 32 pt that gives a portrait
    /// screen its rhythm is a tenth of a landscape phone's viewport, so there
    /// the break is the grid's own gap.
    static func sectionSpacing(compactHeight: Bool) -> CGFloat {
        compactHeight ? Theme.Spacing.grid : sectionSpacing
    }

    /// Gap between the art and the caption beside it.
    static let sideBySideSpacing: CGFloat = Theme.Spacing.md

    /// At most this much of the row goes to the art beside the caption.
    static let sideBySideArtWidthFraction: CGFloat = 0.5

    /// Height for the art beside the caption: TITLEPIC's shape at up to half
    /// the row, shrunk so `minimumGridPeek` of the first tile row still shows
    /// under the compact zone break, never below `minimumArtHeight`. The
    /// caption's height does not enter: it sits beside the art, not under it.
    ///
    /// Its width does (issue #424). The caption holds the hero's two buttons,
    /// whose labels are text at the reader's size and cannot be shrunk, so
    /// `captionMinimumWidth` is what the wider of them needs on one line and
    /// the art gives up whatever of its half that takes. On an open iPhone
    /// Duo turned tall, at the largest accessibility size, half the row was
    /// 312 pt and a button needed more: both labels were cut ("Contin…",
    /// "New Ga…"). The art gives way only down to its floor; a row too narrow
    /// for the floor and a button is narrower than any window that puts the
    /// art beside its caption.
    static func sideBySideArtHeight(contentWidth: CGFloat,
                                    viewportHeight: CGFloat,
                                    captionMinimumWidth: CGFloat = 0) -> CGFloat {
        let row = max(0, contentWidth) - sideBySideSpacing
        let half = row * sideBySideArtWidthFraction
        let floor = min(half, minimumArtHeight * Theme.heroAspectRatio)
        let widest = max(floor, min(half, row - captionMinimumWidth))
        let natural = widest / Theme.heroAspectRatio
        guard viewportHeight.isFinite, viewportHeight > 0 else { return natural }
        let room = viewportHeight - sectionSpacing(compactHeight: true) - minimumGridPeek
        return min(natural, max(room, minimumArtHeight))
    }

    /// The width that goes with `sideBySideArtHeight`: the art keeps its shape.
    static func sideBySideArtWidth(contentWidth: CGFloat,
                                   viewportHeight: CGFloat,
                                   captionMinimumWidth: CGFloat = 0) -> CGFloat {
        sideBySideArtHeight(contentWidth: contentWidth,
                            viewportHeight: viewportHeight,
                            captionMinimumWidth: captionMinimumWidth) * Theme.heroAspectRatio
    }

    /// The whole hero, side by side: the taller of the art and the caption.
    /// The caption is text at the reader's size and cannot be shrunk, so a
    /// caption taller than the art makes the hero taller than the art, and
    /// the grid's peek is spent on it -- the same honest answer the game
    /// page's side-by-side row gives.
    static func sideBySideHeroHeight(contentWidth: CGFloat,
                                     viewportHeight: CGFloat,
                                     captionHeight: CGFloat,
                                     captionMinimumWidth: CGFloat = 0) -> CGFloat {
        max(sideBySideArtHeight(contentWidth: contentWidth,
                                viewportHeight: viewportHeight,
                                captionMinimumWidth: captionMinimumWidth),
            captionHeight)
    }

    /// The width left for the caption beside the art: the row less the art
    /// and the gap between them.
    static func sideBySideCaptionWidth(contentWidth: CGFloat,
                                       viewportHeight: CGFloat,
                                       captionMinimumWidth: CGFloat = 0) -> CGFloat {
        max(0, contentWidth - sideBySideSpacing
            - sideBySideArtWidth(contentWidth: contentWidth,
                                 viewportHeight: viewportHeight,
                                 captionMinimumWidth: captionMinimumWidth))
    }

    /// Gap between the rows of the hero's caption: the title, the last-played
    /// line and the buttons.
    static let captionSpacing: CGFloat = 6

    /// Extra space above the caption's buttons, on top of `captionSpacing`.
    static let captionButtonsTopPadding: CGFloat = Theme.Spacing.sm

    /// Where the Continue button ends, measured from the top of the caption
    /// beside the art. Continue is the caption's first button whether the
    /// buttons share a row or are stacked, so the answer is the same for
    /// both. A `lastPlayedHeight` of zero is a caption without that line.
    static func sideBySideContinueBottom(titleHeight: CGFloat,
                                         lastPlayedHeight: CGFloat,
                                         buttonHeight: CGFloat) -> CGFloat {
        let lastPlayed = lastPlayedHeight > 0 ? lastPlayedHeight + captionSpacing : 0
        return titleHeight + lastPlayed + captionSpacing + captionButtonsTopPadding + buttonHeight
    }

    /// Gap between the two buttons when they are stacked.
    static let buttonColumnSpacing: CGFloat = Theme.Spacing.sm

    /// Where the caption's last button ends, measured from the top of the
    /// caption beside the art: Continue in a row, where New Game is beside
    /// it, and New Game in a column, where it is under Continue (issue #547).
    /// This is the bottom the caption's rules keep inside the viewport, so
    /// that where the buttons stack both of them are whole, not only the
    /// first.
    ///
    /// New Game takes its own height: its label's glyph draws it a pixel
    /// shorter than Continue at the accessibility sizes, and the taller of
    /// the two stood in for it capped titles whose buttons ended exactly on
    /// the viewport.
    static func sideBySideButtonsBottom(titleHeight: CGFloat,
                                        lastPlayedHeight: CGFloat,
                                        buttonHeight: CGFloat,
                                        newGameButtonHeight: CGFloat,
                                        buttonArrangement: ButtonArrangement) -> CGFloat {
        let continueBottom = sideBySideContinueBottom(titleHeight: titleHeight,
                                                      lastPlayedHeight: lastPlayedHeight,
                                                      buttonHeight: buttonHeight)
        switch buttonArrangement {
        case .row: return continueBottom
        case .column: return continueBottom + buttonColumnSpacing + newGameButtonHeight
        }
    }

    /// Whether the caption beside the art keeps its "Last played" line
    /// (issue #457).
    ///
    /// On a closed iPhone Duo held on its side (a 350 pt viewport) at the
    /// largest accessibility size the caption is the title on two lines, the
    /// last-played line on two more, then the buttons, and it is taller than
    /// the viewport: Continue, the screen's primary action, ended 23 pt into
    /// the strip under the home indicator. The line is the one part of the
    /// caption that can go: the art beside it already says which game, and
    /// the game page says when it was played. So it gives way wherever, and
    /// only where, Continue would otherwise end below the viewport with the
    /// shelf at its top; everywhere Continue already fits nothing changes.
    ///
    /// Where the buttons are stacked, New Game is under Continue and is the
    /// caption's bottom, so the rule keeps *it* inside the viewport: at an
    /// accessibility size in a short landscape window, keeping only
    /// Continue whole left New Game cut through its label, under the home
    /// indicator (issue #547). In a row the two end together, and the rule
    /// is what it was.
    ///
    /// Every input is arithmetic over the viewport the scroll view reports
    /// and the reader's fonts, never a frame of the hero's own: a hero that
    /// measured itself to decide its own content could feed itself
    /// (`docs/learnings/a-scroll-view-measured-to-lay-out-its-own-content-can-spin.md`).
    ///
    /// - Parameters:
    ///   - viewportHeight: height visible without scrolling. Zero or
    ///     non-finite means "not measured yet", and the line is kept.
    ///   - contentPadding: the inset above the hero.
    ///   - titleHeight: the title as it wraps at the caption's width.
    ///   - lastPlayedHeight: the last-played line as it wraps there.
    ///   - buttonHeight: one button at the reader's text size.
    ///   - newGameButtonHeight: the New Game button at the reader's text size.
    ///   - buttonArrangement: whether the buttons share a row or are stacked
    ///     (`buttonArrangement(captionWidth:buttonMinimumWidth:)`).
    static func sideBySideCaptionShowsLastPlayed(viewportHeight: CGFloat,
                                                 contentPadding: CGFloat,
                                                 titleHeight: CGFloat,
                                                 lastPlayedHeight: CGFloat,
                                                 buttonHeight: CGFloat,
                                                 newGameButtonHeight: CGFloat,
                                                 buttonArrangement: ButtonArrangement) -> Bool {
        guard viewportHeight.isFinite, viewportHeight > 0 else { return true }
        let bottom = contentPadding + sideBySideButtonsBottom(titleHeight: titleHeight,
                                                              lastPlayedHeight: lastPlayedHeight,
                                                              buttonHeight: buttonHeight,
                                                              newGameButtonHeight: newGameButtonHeight,
                                                              buttonArrangement: buttonArrangement)
        return bottom <= viewportHeight
    }

    /// How many lines the title beside the art may take, or nil for as many
    /// as it wraps to (issue #493).
    ///
    /// Dropping the last-played line (`sideBySideCaptionShowsLastPlayed`) is
    /// not always enough: the title has no line limit of its own, and at an
    /// accessibility size a long one wraps to five lines or more and alone
    /// pushes Continue below a closed Duo's 350 pt viewport. So the title
    /// gives way next, and only then: wherever Continue would end below the
    /// viewport *without* the line, the title is capped at as many lines as
    /// still leave Continue whole above it, never fewer than one, and its
    /// tail is truncated. The art beside it already says which game, the
    /// Continue button's accessibility label still carries the whole name,
    /// and the game page shows it whole. Wherever Continue fits without the
    /// line, nothing changes.
    ///
    /// "Whole" means both buttons where they are stacked: New Game, under
    /// Continue, is then the caption's bottom, and the title gives way for it
    /// as for Continue (issue #547). Wherever both buttons fit, nothing
    /// changes; where they share a row, the rule is what it was.
    ///
    /// The title's height is worked out in lines, from what SwiftUI draws:
    /// its first line, and the step to each line after it
    /// (`titleHeight(lines:firstLine:lineStep:)`). Neither is
    /// `UIFont.lineHeight`, rounded per line or as a whole: SwiftUI rounds
    /// the first line up to the pixel and steps by the text style's own
    /// leading, which is a pixel or two more than `lineHeight` at the
    /// standard sizes and up to three points less at the largest, and it is
    /// the same for every script. `lineHeight`-based arithmetic was short of
    /// the drawing by up to 1.7 pt in some windows and over it by more in
    /// others, which capped titles that fitted exactly.
    ///
    /// Like the line's rule, every input is arithmetic over the viewport, the
    /// reader's fonts and views that are never the hero's own; nothing reads
    /// a frame of the hero's.
    ///
    /// - Parameters:
    ///   - viewportHeight: height visible without scrolling. Zero or
    ///     non-finite means "not measured yet", and the title is not capped.
    ///   - contentPadding: the inset above the hero.
    ///   - titleLines: how many lines the title wraps to at the caption's width.
    ///   - titleFirstLine: the height of one line of the title as drawn.
    ///   - titleLineStep: what each further line adds as drawn. Zero or less
    ///     for either means "not measured yet", and the title is not capped.
    ///   - buttonHeight: one button at the reader's text size.
    ///   - newGameButtonHeight: the New Game button at the reader's text size.
    ///   - buttonArrangement: whether the buttons share a row or are stacked.
    static func sideBySideTitleLineLimit(viewportHeight: CGFloat,
                                         contentPadding: CGFloat,
                                         titleLines: Int,
                                         titleFirstLine: CGFloat,
                                         titleLineStep: CGFloat,
                                         buttonHeight: CGFloat,
                                         newGameButtonHeight: CGFloat,
                                         buttonArrangement: ButtonArrangement) -> Int? {
        guard viewportHeight.isFinite, viewportHeight > 0,
              titleFirstLine > 0, titleLineStep > 0, titleLines > 1 else { return nil }
        let below = sideBySideButtonsBottom(titleHeight: 0, lastPlayedHeight: 0, buttonHeight: buttonHeight,
                                            newGameButtonHeight: newGameButtonHeight,
                                            buttonArrangement: buttonArrangement)
        // Every input is on the pixel grid, so a title that ends Continue
        // on the viewport is one that fits; the tolerance, far below a
        // pixel, keeps floating-point noise in a sum of thirds from saying
        // it does not.
        let room = viewportHeight - contentPadding - below + 0.001
        func height(_ lines: Int) -> CGFloat {
            titleHeight(lines: lines, firstLine: titleFirstLine, lineStep: titleLineStep)
        }
        guard height(titleLines) > room else { return nil }
        var lines = titleLines - 1
        while lines > 1, height(lines) > room { lines -= 1 }
        return lines
    }

    /// A title of `lines` lines as SwiftUI draws it: the first line, then
    /// one step for each line after it.
    static func titleHeight(lines: Int, firstLine: CGFloat, lineStep: CGFloat) -> CGFloat {
        guard lines > 0 else { return 0 }
        return firstLine + CGFloat(lines - 1) * lineStep
    }

    /// How the caption's two buttons, Continue and New Game, are stacked.
    enum ButtonArrangement: Equatable {
        case row
        case column
    }

    /// Gap between the two buttons when they share a row.
    static let buttonRowSpacing: CGFloat = Theme.Spacing.md

    /// A row only where the caption holds two buttons of the WIDER label's
    /// width, because that is how a row is drawn: both buttons stretch, so
    /// the row is split evenly. Asking only whether the two natural widths
    /// fit side by side (what `ViewThatFits` asks) let the row through
    /// wherever the sum fitted, and the even split then cut the wider label:
    /// "New Ga…" on an open iPhone Duo at `accessibility-medium`, and on a
    /// landscape iPhone at `accessibility-large` (issue #424).
    ///
    /// - Parameter buttonMinimumWidth: what the wider button needs to show
    ///   its label whole. Zero means "not measured yet" and keeps the row,
    ///   which is what every window draws at the default text size.
    static func buttonArrangement(captionWidth: CGFloat,
                                  buttonMinimumWidth: CGFloat) -> ButtonArrangement {
        guard buttonMinimumWidth > 0 else { return .row }
        return buttonMinimumWidth * 2 + buttonRowSpacing <= captionWidth ? .row : .column
    }

    /// The welcome card's own metrics: 16 pt of padding all round, 12 pt
    /// between its rows. Constants because they are literals in `ShelfView`'s
    /// card and do not scale with Dynamic Type; everything that *does* scale is
    /// measured and passed into `welcomeCardHeight` below.
    static let welcomeCardPadding: CGFloat = 16
    static let welcomeCardRowSpacing: CGFloat = 12

    /// The card's height, from the rows whose heights follow the reader's
    /// text size.
    ///
    /// Two rows, not three, since the 2026-08-21 design pass: the card's app
    /// name duplicated the navigation title sitting directly above it, so the
    /// name now lives only in the bar and the card is the tagline over the
    /// button (spec §4, amended). The compact form is the button alone.
    ///
    /// Measured rather than assumed, for the same reason `artHeight` takes a
    /// `captionHeight` instead of hard-coding one: the description and the
    /// button label both grow at accessibility sizes, and a budget written
    /// against the default size would clear a card half again as tall and put
    /// the first tile row right back below the fold.
    ///
    /// - Parameter descriptionHeight: zero for the compact form — the card
    ///   without its description line — which also drops the row gap.
    ///
    /// - Parameter compactHeight: on a landscape phone the tagline sits
    ///   beside the button rather than over it, so the card is as tall as its
    ///   taller column; the compact form (no description) is the same height
    ///   either way.
    static func welcomeCardHeight(descriptionHeight: CGFloat,
                                  buttonHeight: CGFloat,
                                  compactHeight: Bool = false) -> CGFloat {
        if compactHeight && descriptionHeight > 0 {
            return welcomeCardPadding * 2 + max(descriptionHeight, buttonHeight)
        }
        let rows = descriptionHeight > 0
            ? [descriptionHeight, buttonHeight]
            : [buttonHeight]
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
                               gridSpacing: CGFloat,
                               compactHeight: Bool = false) -> CGFloat {
        // The row as the shelf draws it: a tile's own shape, or the
        // viewport's cap on it (`PlayableTileLayout.tileHeight`).
        let tileRowHeight = PlayableTileLayout.tileHeight(
            width: gridColumnWidth(contentWidth: contentWidth,
                                   minimum: tileMinimumWidth,
                                   spacing: gridSpacing),
            viewportHeight: viewportHeight,
            contentPadding: contentPadding)
        return viewportHeight - contentPadding * 2
            - sectionSpacing(compactHeight: compactHeight) - tileRowHeight
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
    /// Dropping the description keeps the element spec §4 leads with — the
    /// primary **Add Your Games** button. (The app name left the card in the
    /// 2026-08-21 amendment; the navigation title carries it.)
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
                                            fullCardHeight: CGFloat,
                                            compactHeight: Bool = false) -> Bool {
        guard viewportHeight.isFinite, viewportHeight > 0 else { return true }
        let budget = heroZoneBudget(viewportHeight: viewportHeight,
                                    contentWidth: contentWidth,
                                    tileMinimumWidth: tileMinimumWidth,
                                    contentPadding: contentPadding,
                                    gridSpacing: gridSpacing,
                                    compactHeight: compactHeight)
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
                          captionHeight: CGFloat = defaultCaptionHeight,
                          gridPeek: CGFloat = minimumGridPeek) -> CGFloat {
        let natural = max(0, contentWidth) / Theme.heroAspectRatio
        guard viewportHeight.isFinite, viewportHeight > 0 else { return natural }
        let room = viewportHeight - captionHeight - sectionSpacing - gridPeek
        return min(natural, max(room, minimumArtHeight))
    }

    /// How much room the stacked hero leaves beneath its caption for the
    /// first tile row.
    ///
    /// On anything phone-sized this is `minimumGridPeek`, unchanged. On a
    /// wide window (`Theme.wideGridContentWidth`) it is the whole row: the
    /// wider tiles issue #353 gives those windows are taller than the peek,
    /// and a hero sized for a 120 pt peek put the row's bottom edge, which is
    /// where its title is, under the fold on an open iPhone Duo. A wide
    /// window has the height to show the row whole, so it does.
    ///
    /// "Whole" has to count the shelf's top inset as well. The viewport
    /// `artHeight` budgets against starts above that inset, so a reserve of
    /// the row's height alone ends the row `contentPadding` below the fold;
    /// the phone's peek never promised a whole row, so it was never owed
    /// that, and stays as it is.
    static func gridPeek(contentWidth: CGFloat,
                         tileMinimumWidth: CGFloat,
                         gridSpacing: CGFloat,
                         contentPadding: CGFloat,
                         viewportHeight: CGFloat = 0) -> CGFloat {
        guard contentWidth >= Theme.wideGridContentWidth else { return minimumGridPeek }
        // The row as the shelf draws it, which in a short window is the
        // viewport's cap on a tile and not its 4:3 shape. Zero, "not
        // measured yet", is the shape.
        let rowHeight = PlayableTileLayout.tileHeight(
            width: gridColumnWidth(contentWidth: contentWidth,
                                   minimum: tileMinimumWidth,
                                   spacing: gridSpacing),
            viewportHeight: viewportHeight,
            contentPadding: contentPadding)
        return max(minimumGridPeek, rowHeight + contentPadding)
    }
}
