import UIKit
import XCTest
@testable import Waddle

/// What the hero is actually laid out against: the width it is drawn at and
/// the height visible without scrolling, both derived from device bounds in
/// points (CoreSimulator `mainScreenWidth`/`Height` / `mainScreenScale`) less
/// the chrome above and below.
///
/// The chrome figures are close but not exact -- an inline navigation bar is
/// 44 pt, a large-title one nearer 96, the home indicator 21 or 34 depending
/// on orientation -- so every assertion below is written to tolerate a few
/// points either way rather than pinning a rendered result. What matters is
/// the relationship between the hero and the space around it, which is what
/// `ShelfHeroLayout` decides.
private struct Viewport {
    let contentWidth: CGFloat
    let height: CGFloat

    /// Natural full-width height of the hero's art here: what it was before
    /// this type existed, and still is wherever it fits.
    var naturalArtHeight: CGFloat { contentWidth / Theme.heroAspectRatio }

    /// iPhone 17 Pro Max landscape -- the device #159 was measured on.
    /// 2868x1320@3 = 956x440 pt, less 59 pt of sensor-housing safe area on
    /// each side and the shelf's own 16 pt padding on each side, less a 44 pt
    /// navigation bar and a 21 pt home indicator.
    static let landscapePhone = Viewport(contentWidth: 956 - 59 * 2 - 32,
                                         height: 440 - 44 - 21)
    /// iPhone 17 Pro portrait: 1206x2622@3 = 402x874 pt.
    static let portraitPhone = Viewport(contentWidth: 402 - 32,
                                        height: 874 - 96 - 34)
    /// iPad Pro 13" M4 portrait: 2064x2752@2 = 1032x1376 pt.
    static let portraitPad = Viewport(contentWidth: 1032 - 32,
                                      height: 1376 - 96 - 20)
    /// iPad Pro 13" M4 landscape.
    static let landscapePad = Viewport(contentWidth: 1376 - 32,
                                       height: 1032 - 96 - 20)
}

final class ShelfHeroLayoutTests: XCTestCase {
    private func artHeight(_ viewport: Viewport,
                           captionHeight: CGFloat = ShelfHeroLayout.defaultCaptionHeight) -> CGFloat {
        ShelfHeroLayout.artHeight(contentWidth: viewport.contentWidth,
                                  viewportHeight: viewport.height,
                                  captionHeight: captionHeight)
    }

    /// Height left for the grid once the hero -- art, title, Continue line --
    /// and the gap below it have taken their share of the viewport.
    private func gridBand(_ viewport: Viewport,
                          captionHeight: CGFloat = ShelfHeroLayout.defaultCaptionHeight) -> CGFloat {
        viewport.height - artHeight(viewport, captionHeight: captionHeight)
            - captionHeight - ShelfHeroLayout.sectionSpacing
    }

    // MARK: - The defect

    /// The bug, stated as geometry: on a landscape phone the unconstrained
    /// hero was about 500 pt of art in a viewport of about 375, so the grid
    /// and the hero's own caption were both below the fold. Remove the cap in
    /// `ShelfHeroLayout.artHeight` and this is the assertion that fails.
    func testLandscapePhoneLeavesTheFirstTileRowAboveTheFold() {
        let viewport = Viewport.landscapePhone
        // The premise: without a cap there would not have been room.
        XCTAssertGreaterThan(viewport.naturalArtHeight, viewport.height)

        XCTAssertGreaterThanOrEqual(gridBand(viewport), ShelfHeroLayout.minimumGridPeek)
        // A LazyVGrid omits off-screen cells entirely, so this band is also
        // what puts the first row in the accessibility hierarchy at all -- and
        // it clears spec §5's 44 pt target, so that row is tappable without
        // scrolling rather than merely peeking.
        XCTAssertGreaterThan(gridBand(viewport), Theme.minimumTapTarget)
    }

    /// The hero's caption is part of the hero: reserving space for the grid
    /// but not for the title and Continue line would move the problem down a
    /// view instead of fixing it.
    func testLandscapePhoneKeepsTheCaptionInFrame() {
        let viewport = Viewport.landscapePhone
        let heroHeight = artHeight(viewport) + ShelfHeroLayout.defaultCaptionHeight
        XCTAssertLessThan(heroHeight, viewport.height)
    }

    /// A cap, not a demotion (spec §5 still has the hero leading the screen):
    /// even at its most constrained the art stays the largest thing on the
    /// screen -- taller than its own caption and taller than the visible grid.
    func testLandscapePhoneHeroStillLeadsTheScreen() {
        let viewport = Viewport.landscapePhone
        XCTAssertGreaterThan(artHeight(viewport), ShelfHeroLayout.defaultCaptionHeight)
        XCTAssertGreaterThan(artHeight(viewport), gridBand(viewport))
    }

    // MARK: - Where the hero already fit

    func testPortraitPhoneIsUnchanged() {
        let viewport = Viewport.portraitPhone
        XCTAssertEqual(artHeight(viewport), viewport.naturalArtHeight, accuracy: 0.001)
    }

    func testPortraitPadIsUnchanged() {
        let viewport = Viewport.portraitPad
        XCTAssertEqual(artHeight(viewport), viewport.naturalArtHeight, accuracy: 0.001)
    }

    /// Both of the above with room to spare, so a few points of misjudged
    /// chrome cannot flip them into the capped branch: a test that only
    /// happens to pass at exactly the insets guessed above would be worthless
    /// on the next device.
    func testUncappedSizesHaveHeadroom() {
        for viewport in [Viewport.portraitPhone, Viewport.portraitPad] {
            XCTAssertGreaterThan(viewport.height - viewport.naturalArtHeight, 200)
        }
    }

    /// A landscape iPad is the same defect in milder form -- about 840 pt of
    /// art in a viewport of about 916 -- so it is capped too, and the issue's
    /// "iPad already fits" describes the portrait case above rather than this
    /// one. The cap is gentle here: the hero still takes better than two
    /// thirds of the screen.
    func testLandscapePadIsCappedButStillDominant() {
        let viewport = Viewport.landscapePad
        XCTAssertGreaterThan(viewport.naturalArtHeight, artHeight(viewport))
        XCTAssertGreaterThan(artHeight(viewport), viewport.height * 2 / 3)
        XCTAssertGreaterThanOrEqual(gridBand(viewport), ShelfHeroLayout.minimumGridPeek)
    }

    // MARK: - Edges

    /// The first frame, before `onGeometryChange` has reported anything. An
    /// unmeasured viewport must read as "no constraint known yet" and not as
    /// "no room at all", or the hero flashes at its floor height and then
    /// grows.
    func testUnmeasuredViewportKeepsTheNaturalHeight() {
        let viewport = Viewport.landscapePhone
        XCTAssertEqual(ShelfHeroLayout.artHeight(contentWidth: viewport.contentWidth,
                                                 viewportHeight: 0),
                       viewport.naturalArtHeight, accuracy: 0.001)
        XCTAssertEqual(ShelfHeroLayout.artHeight(contentWidth: viewport.contentWidth,
                                                 viewportHeight: .infinity),
                       viewport.naturalArtHeight, accuracy: 0.001)
    }

    /// At accessibility sizes the caption block is much taller -- around
    /// 120 pt at AX5, where `.title2` alone is near 60 -- and it is the art
    /// that gives way, not the grid and not the caption. That is the whole
    /// point of `ShelfView` measuring the caption through `UIFont` instead of
    /// assuming a default-size constant.
    func testAccessibilityCaptionShrinksTheArtNotTheRest() {
        let viewport = Viewport.landscapePhone
        let large: CGFloat = 120
        XCTAssertLessThan(artHeight(viewport, captionHeight: large), artHeight(viewport))
        XCTAssertGreaterThanOrEqual(gridBand(viewport, captionHeight: large),
                                    ShelfHeroLayout.minimumGridPeek)
    }

    /// Every extra point the caption takes comes out of the art, all the way
    /// down -- no size prefers a shorter caption to a shorter hero.
    func testTallerCaptionsNeverProduceTallerArt() {
        let viewport = Viewport.landscapePhone
        for caption in stride(from: 40.0, through: 240.0, by: 10.0) {
            XCTAssertLessThanOrEqual(artHeight(viewport, captionHeight: caption + 10),
                                     artHeight(viewport, captionHeight: caption))
        }
    }

    /// A viewport too short to hold everything -- a small iPad window, or an
    /// accessibility size on a small landscape phone. Below this point the
    /// three claims on the screen cannot all be met, and the order of
    /// surrender is deliberate: the art stops giving way at a height where it
    /// still reads as art, the caption keeps its full measured space, and the
    /// grid is the one that goes back to being reached by scrolling. A hero
    /// shrunk to a strip would serve nobody.
    func testVeryShortViewportFloorsTheArtAndYieldsTheGridBand() {
        let cramped = Viewport(contentWidth: 700, height: 200)
        XCTAssertEqual(artHeight(cramped), ShelfHeroLayout.minimumArtHeight, accuracy: 0.001)
        XCTAssertLessThan(gridBand(cramped), ShelfHeroLayout.minimumGridPeek)
    }

    /// The cap only ever takes height away. On a tall enough viewport the art
    /// is exactly what its aspect ratio asks for, never stretched to fill.
    func testCapNeverGrowsTheArt() {
        for height in stride(from: 200.0, through: 2000.0, by: 50.0) {
            let viewport = Viewport(contentWidth: 800, height: height)
            XCTAssertLessThanOrEqual(artHeight(viewport), viewport.naturalArtHeight)
        }
    }

    // MARK: - The welcome card (#183)

    /// `.borderedProminent`'s own vertical padding around its label, on top of
    /// the `Theme.minimumTapTarget` floor the label already claims. Measured
    /// from the rendered hierarchy, the way `PlayableDetailLayout`'s row
    /// figures were, and tolerated a few points either way like everything
    /// else here.
    private static let buttonChrome: CGFloat = 14

    /// What the real card measures at a given content size: the three rows
    /// `ShelfView` draws, at the line heights `UIFont` reports for that size.
    /// Derived rather than pinned, so this keeps describing the card if a
    /// future OS changes a font's metrics.
    ///
    /// - Parameter bodyLines: how many lines the explanatory sentence wraps to
    ///   at the viewport's width — one on a wide landscape phone, more as the
    ///   width narrows or the type grows.
    private func naturalCardHeight(_ category: UIContentSizeCategory,
                                   bodyLines: Int) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let body = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).lineHeight
        let label = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).lineHeight
        return ShelfHeroLayout.welcomeCardNaturalHeight(
            nameLineHeight: UIFont.preferredFont(forTextStyle: .title1,
                                                 compatibleWith: traits).lineHeight,
            bodyHeight: body * CGFloat(bodyLines),
            buttonHeight: max(Theme.minimumTapTarget, label) + Self.buttonChrome)
    }

    private func cardHeight(_ viewport: Viewport, natural: CGFloat) -> CGFloat {
        ShelfHeroLayout.welcomeCardHeight(naturalHeight: natural,
                                          viewportHeight: viewport.height)
    }

    /// Height left for the grid once the card and the gap below it have taken
    /// their share. The card holds its own title, line and button, so unlike
    /// the hero there is no separate caption to subtract.
    private func cardGridBand(_ viewport: Viewport, natural: CGFloat) -> CGFloat {
        viewport.height - cardHeight(viewport, natural: natural) - ShelfHeroLayout.sectionSpacing
    }

    /// The defect, stated as geometry. At an accessibility type size the card's
    /// three rows are two to three times their default height, and on a
    /// landscape phone that unbounded card leaves the first tile row below the
    /// fold — where a `LazyVGrid` never instantiates it, so it cannot be
    /// long-pressed or even found. Remove the ceiling from
    /// `ShelfHeroLayout.welcomeCardMaxHeight` and this is the assertion that
    /// fails.
    func testLandscapePhoneWelcomeCardLeavesTheFirstTileRowAboveTheFold() {
        let viewport = Viewport.landscapePhone
        // Two lines: at ~806 pt of content width the sentence sits on one at
        // the default type size, and wraps once the type grows. Two is the
        // conservative read of how far it wraps at AX5.
        let natural = naturalCardHeight(.accessibilityExtraExtraExtraLarge, bodyLines: 2)

        // The premise: without a ceiling there would not have been room.
        XCTAssertGreaterThan(natural + ShelfHeroLayout.sectionSpacing
                                + ShelfHeroLayout.minimumGridPeek,
                             viewport.height)

        XCTAssertGreaterThanOrEqual(cardGridBand(viewport, natural: natural),
                                    ShelfHeroLayout.minimumGridPeek)
        // And that band clears spec §5's target, so the row is tappable
        // without scrolling rather than merely peeking.
        XCTAssertGreaterThan(cardGridBand(viewport, natural: natural), Theme.minimumTapTarget)
    }

    /// The card's own three rows stay in frame: the ceiling never drops below
    /// the floor that holds them, so bounding the card cannot crop the app
    /// name, the line, or the Add Your Games button off it.
    func testWelcomeCardCeilingNeverDropsBelowItsOwnRows() {
        for viewport in [Viewport.landscapePhone, .portraitPhone, .portraitPad, .landscapePad] {
            let ceiling = try? XCTUnwrap(
                ShelfHeroLayout.welcomeCardMaxHeight(viewportHeight: viewport.height))
            XCTAssertGreaterThanOrEqual(ceiling ?? 0,
                                        ShelfHeroLayout.minimumWelcomeCardHeight)
        }
        // The floor is a real measurement of those rows, not a round number:
        // it has to hold the default-size card, and specifically the wrapped
        // two-line shape it takes at the narrow widths where a viewport short
        // enough to reach the floor actually occurs.
        XCTAssertGreaterThanOrEqual(ShelfHeroLayout.minimumWelcomeCardHeight,
                                    naturalCardHeight(.large, bodyLines: 2))
    }

    /// Where the card already fit, it is untouched — the ceiling is inert at
    /// the default type size on every device but the shortest.
    func testWelcomeCardIsUnchangedAtPortraitAndPadBounds() {
        for viewport in [Viewport.portraitPhone, .portraitPad, .landscapePad] {
            let natural = naturalCardHeight(.large, bodyLines: 2)
            XCTAssertEqual(cardHeight(viewport, natural: natural), natural, accuracy: 0.001,
                           "card shrunk at \(viewport.height) pt of viewport")
        }
    }

    /// Including the landscape phone at the default type size, which is the
    /// size the issue's own repro ran at: the card measures well under the room
    /// available, so this change moves nothing there.
    func testWelcomeCardIsUnchangedOnALandscapePhoneAtDefaultType() {
        let viewport = Viewport.landscapePhone
        let natural = naturalCardHeight(.large, bodyLines: 1)
        XCTAssertEqual(cardHeight(viewport, natural: natural), natural, accuracy: 0.001)
        XCTAssertGreaterThan(cardGridBand(viewport, natural: natural),
                             ShelfHeroLayout.minimumGridPeek)
    }

    /// The first frame, before `onGeometryChange` has reported anything. An
    /// unmeasured viewport must read as "no ceiling known yet" and not as "no
    /// room at all".
    func testUnmeasuredViewportImposesNoWelcomeCardCeiling() {
        // nil, not .infinity: `.frame(maxHeight: .infinity)` would stretch the
        // card to fill instead of leaving it alone.
        XCTAssertNil(ShelfHeroLayout.welcomeCardMaxHeight(viewportHeight: 0))
        XCTAssertNil(ShelfHeroLayout.welcomeCardMaxHeight(viewportHeight: .infinity))
        let natural = naturalCardHeight(.large, bodyLines: 2)
        XCTAssertEqual(ShelfHeroLayout.welcomeCardHeight(naturalHeight: natural,
                                                         viewportHeight: 0),
                       natural, accuracy: 0.001)
    }

    /// A viewport too short to hold both. The order of surrender matches the
    /// hero's: the card keeps the height its rows need and the grid goes back
    /// to being reached by scrolling, rather than the card losing a row.
    func testVeryShortViewportFloorsTheWelcomeCardAndYieldsTheGridBand() {
        let cramped = Viewport(contentWidth: 700, height: 200)
        let natural = naturalCardHeight(.accessibilityExtraExtraExtraLarge, bodyLines: 2)
        XCTAssertEqual(cardHeight(cramped, natural: natural),
                       ShelfHeroLayout.minimumWelcomeCardHeight, accuracy: 0.001)
        XCTAssertLessThan(cardGridBand(cramped, natural: natural),
                          ShelfHeroLayout.minimumGridPeek)
    }

    /// The ceiling only ever takes height away, and never stretches a short
    /// card to fill a tall screen.
    func testWelcomeCardCeilingNeverGrowsTheCard() {
        let natural = naturalCardHeight(.large, bodyLines: 1)
        for height in stride(from: 200.0, through: 2000.0, by: 50.0) {
            XCTAssertLessThanOrEqual(
                ShelfHeroLayout.welcomeCardHeight(naturalHeight: natural, viewportHeight: height),
                natural)
        }
    }
}
