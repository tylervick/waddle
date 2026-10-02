import XCTest
@testable import Waddle

/// What the detail page's art is laid out against: the width its `Form` row
/// offers and the height visible without scrolling. Written the same way as
/// `ShelfHeroLayoutTests` -- over supplied bounds, tolerating a few points
/// either way rather than pinning a rendered result, because what matters is
/// the relationship between the art and the controls under it.
private struct Sheet {
    let contentWidth: CGFloat
    let height: CGFloat

    /// Natural full-width height of the art here: TITLEPIC's own landscape
    /// shape, which is what it gets wherever it fits.
    var naturalArtHeight: CGFloat { contentWidth / Theme.heroAspectRatio }

    /// iPhone 17 Pro portrait, the device this bug was measured on: 402 pt
    /// wide, less 16 pt of `Form` row inset on each side. A full-height sheet
    /// starts 62 pt down and runs to the bottom, less a 54 pt inline
    /// navigation bar and a 34 pt home indicator.
    static let portraitPhone = Sheet(contentWidth: 402 - 32,
                                     height: 874 - 62 - 54 - 34)

    /// iPhone 17 Pro landscape: 874x402 pt, less 16 pt row insets and the
    /// same chrome. The short viewport is the case a ratio alone gets wrong.
    static let landscapePhone = Sheet(contentWidth: 874 - 32,
                                      height: 402 - 54 - 21)
}

final class PlayableDetailLayoutTests: XCTestCase {

    private func artHeight(_ sheet: Sheet,
                           captionHeight: CGFloat = PlayableDetailLayout.defaultCaptionHeight) -> CGFloat {
        PlayableDetailLayout.artHeight(contentWidth: sheet.contentWidth,
                                       viewportHeight: sheet.height,
                                       captionHeight: captionHeight)
    }

    // MARK: The bug this type exists for

    /// The regression proper. Portrait is the orientation both failing UI
    /// tests run in, and the art has to leave the whole of a preset's Contents
    /// section -- header through the Edit button that ends it -- above the
    /// fold, or a lazy `Form` never instantiates the rows the tests reach for.
    func testPortraitLeavesRoomForTheControlsBelowTheArt() {
        let sheet = Sheet.portraitPhone
        let art = artHeight(sheet)
        let used = art + PlayableDetailLayout.defaultCaptionHeight
        XCTAssertGreaterThanOrEqual(sheet.height - used,
                                    PlayableDetailLayout.minimumControlsPeek,
                                    "art plus header left \(sheet.height - used) pt for the controls")
    }

    /// The old behaviour, stated as the thing that must not come back: the
    /// tile's 3:4 crop at this width is 481 pt, which is more than the sheet
    /// has to spare once the header and controls are accounted for.
    ///
    /// The 3:4 is a literal, not `Theme.tileAspectRatio`: the bug was the
    /// header drawing art at the *portrait* tile shape of the time, and tiles
    /// have since gone 4:3 (spec §5, 2026-08-18). Reading the live constant
    /// made this measure 277 pt against a 269 pt budget — still "over", by 8
    /// pt, until the 2026-09-30 header slimmed the caption and the test
    /// flipped without the bug coming back. Re-anchored to the geometry it
    /// describes; see `docs/learnings/tile-aspect-is-an-input-to-the-fold-budget.md`.
    func testTileAspectRatioWouldNotHaveFit() {
        let sheet = Sheet.portraitPhone
        let portraitTileAspect: CGFloat = 3.0 / 4.0
        let tileShaped = sheet.contentWidth / portraitTileAspect
        let budget = sheet.height - PlayableDetailLayout.defaultCaptionHeight
            - PlayableDetailLayout.minimumControlsPeek
        XCTAssertGreaterThan(tileShaped, budget,
                             "the 3:4 crop would have fit, so this test no longer describes the bug")
        XCTAssertLessThanOrEqual(artHeight(sheet), budget)
    }

    // MARK: The cap

    /// Where it fits, the art is not shrunk: portrait has room for the natural
    /// landscape shape, and a cap that clipped it there would be trading away
    /// the header's whole point for nothing.
    func testNaturalHeightIsKeptWhereItFits() {
        let sheet = Sheet.portraitPhone
        XCTAssertEqual(artHeight(sheet), sheet.naturalArtHeight, accuracy: 0.5)
    }

    /// Landscape is the case an aspect ratio alone gets wrong: the art is
    /// wider there, so its natural height grows exactly as the viewport
    /// shrinks.
    func testLandscapeCapsTheArtWellBelowItsNaturalHeight() {
        let sheet = Sheet.landscapePhone
        let art = artHeight(sheet)
        XCTAssertLessThan(art, sheet.naturalArtHeight)
        XCTAssertLessThan(art, sheet.height)
    }

    /// The floor holds even when the arithmetic asks for less than nothing --
    /// a viewport this short cannot show everything at once, and the answer is
    /// art that still reads as art plus scrolling, not a zero-height strip.
    func testNeverShrinksBelowTheFloor() {
        let cramped = Sheet(contentWidth: 800, height: 200)
        XCTAssertEqual(artHeight(cramped), PlayableDetailLayout.minimumArtHeight, accuracy: 0.5)
    }

    /// Zero and non-finite viewports mean "not measured yet" -- the first
    /// frame must show the natural shape rather than flash a clamped one.
    func testUnmeasuredViewportKeepsTheNaturalHeight() {
        let width = Sheet.portraitPhone.contentWidth
        let natural = width / Theme.heroAspectRatio
        XCTAssertEqual(PlayableDetailLayout.artHeight(contentWidth: width, viewportHeight: 0),
                       natural, accuracy: 0.5)
        XCTAssertEqual(PlayableDetailLayout.artHeight(contentWidth: width, viewportHeight: .nan),
                       natural, accuracy: 0.5)
        XCTAssertEqual(PlayableDetailLayout.artHeight(contentWidth: width, viewportHeight: .infinity),
                       natural, accuracy: 0.5)
    }

    /// A negative width is nonsense, not a reason to return a negative height.
    func testNegativeWidthClampsToZero() {
        XCTAssertEqual(PlayableDetailLayout.artHeight(contentWidth: -50, viewportHeight: 0), 0,
                       accuracy: 0.5)
    }

    // MARK: Side by side (design-system spec §8)

    /// iPad Pro 13-inch landscape: 1366 x 1024 pt, less the Form's row insets
    /// and an inline bar plus the home indicator.
    private static let landscapePad = Sheet(contentWidth: 1366 - 32, height: 1024 - 54 - 20)

    /// Portrait and unmeasured pages stack; a page wider than it is tall puts
    /// the art beside the caption. This is the rule that takes a landscape
    /// phone off the 96 pt floor.
    func testArrangementFollowsTheViewportsShape() {
        XCTAssertEqual(PlayableDetailLayout.arrangement(contentWidth: 370, viewportHeight: 724), .stacked)
        XCTAssertEqual(PlayableDetailLayout.arrangement(contentWidth: 842, viewportHeight: 327), .sideBySide)
        XCTAssertEqual(PlayableDetailLayout.arrangement(contentWidth: 1334, viewportHeight: 950), .sideBySide)
        XCTAssertEqual(PlayableDetailLayout.arrangement(contentWidth: 842, viewportHeight: 0), .stacked)
        XCTAssertEqual(PlayableDetailLayout.arrangement(contentWidth: 842, viewportHeight: .nan), .stacked)
    }

    /// The point of the arrangement: on a landscape phone the art is a
    /// picture, well above the floor the stacked budget left it on.
    func testSideBySideLiftsTheLandscapePhoneOffTheFloor() {
        let sheet = Sheet.landscapePhone
        let stacked = artHeight(sheet)
        let beside = PlayableDetailLayout.sideBySideArtHeight(contentWidth: sheet.contentWidth,
                                                              viewportHeight: sheet.height)
        XCTAssertEqual(stacked, PlayableDetailLayout.minimumArtHeight, accuracy: 0.5,
                       "the stacked case no longer floors, so this test no longer describes the trade")
        XCTAssertGreaterThan(beside, stacked * 2)
    }

    /// The art never takes more than its share of the row, so the title and
    /// two buttons always have at least half the width.
    func testSideBySideArtNeverExceedsHalfTheRow() {
        for sheet in [Sheet.landscapePhone, Self.landscapePad] {
            let width = PlayableDetailLayout.sideBySideArtWidth(contentWidth: sheet.contentWidth,
                                                                viewportHeight: sheet.height)
            XCTAssertLessThanOrEqual(width, sheet.contentWidth * PlayableDetailLayout.sideBySideArtWidthFraction + 0.5,
                                     "\(sheet.contentWidth) wide")
        }
    }

    /// Whatever the viewport, one tap target of the next section stays below
    /// the hero row -- the side-by-side twin of the stacked peek rule.
    func testSideBySideLeavesATapTargetOfPeek() {
        for sheet in [Sheet.landscapePhone, Self.landscapePad,
                      Sheet(contentWidth: 812 - 32, height: 375 - 44 - 21)] { // the smallest landscape phone
            let art = PlayableDetailLayout.sideBySideArtHeight(contentWidth: sheet.contentWidth,
                                                               viewportHeight: sheet.height)
            let row = PlayableDetailLayout.captionTopPadding + art + PlayableDetailLayout.captionBottomPadding
            XCTAssertGreaterThanOrEqual(sheet.height - row, Theme.minimumTapTarget - 0.5,
                                        "\(sheet.contentWidth)x\(sheet.height)")
        }
    }

    /// Where there is room, the art keeps its shape at its full share: the
    /// landscape iPad is natural-bound, not peek-bound.
    func testSideBySideKeepsTheNaturalHeightOnAPad() {
        let sheet = Self.landscapePad
        let natural = (sheet.contentWidth - PlayableDetailLayout.captionSpacing)
            * PlayableDetailLayout.sideBySideArtWidthFraction / Theme.heroAspectRatio
        XCTAssertEqual(PlayableDetailLayout.sideBySideArtHeight(contentWidth: sheet.contentWidth,
                                                                viewportHeight: sheet.height),
                       natural, accuracy: 0.5)
    }

    /// Width and height agree on TITLEPIC's shape.
    func testSideBySideArtKeepsTheHeroAspect() {
        let sheet = Sheet.landscapePhone
        let h = PlayableDetailLayout.sideBySideArtHeight(contentWidth: sheet.contentWidth, viewportHeight: sheet.height)
        let w = PlayableDetailLayout.sideBySideArtWidth(contentWidth: sheet.contentWidth, viewportHeight: sheet.height)
        XCTAssertEqual(w / h, Theme.heroAspectRatio, accuracy: 0.001)
    }

    /// The floor holds here too.
    func testSideBySideNeverShrinksBelowTheFloor() {
        XCTAssertEqual(PlayableDetailLayout.sideBySideArtHeight(contentWidth: 800, viewportHeight: 120),
                       PlayableDetailLayout.minimumArtHeight, accuracy: 0.5)
    }

    // MARK: The caption it budgets against

    /// Two primary buttons (Continue and New Game) reserve more than one
    /// (Play), because the item with a save to resume is the one whose header
    /// is taller -- budgeting for the shorter header would push its controls
    /// back off the bottom.
    func testResumableItemReservesMoreThanAFreshOne() {
        let one = PlayableDetailLayout.captionHeight(titleLineHeight: 26.3,
                                                     buttonLineHeight: 20.3,
                                                     primaryButtonCount: 1)
        let two = PlayableDetailLayout.captionHeight(titleLineHeight: 26.3,
                                                     buttonLineHeight: 20.3,
                                                     primaryButtonCount: 2)
        XCTAssertGreaterThan(two, one)
        XCTAssertEqual(one, PlayableDetailLayout.defaultCaptionHeight, accuracy: 0.5)
    }

    /// Accessibility type sizes reserve more, which is the whole reason
    /// `GamePageView` measures this from `UIFont` instead of taking the
    /// default constant.
    func testLargerTypeReservesMoreRoom() {
        let ordinary = PlayableDetailLayout.captionHeight(titleLineHeight: 26.3,
                                                          buttonLineHeight: 20.3,
                                                          primaryButtonCount: 1)
        let accessible = PlayableDetailLayout.captionHeight(titleLineHeight: 52,
                                                            buttonLineHeight: 41,
                                                            primaryButtonCount: 1)
        XCTAssertGreaterThan(accessible, ordinary)
    }

    /// A taller caption comes out of the art's budget, not the controls'.
    func testTallerCaptionShrinksTheArt() {
        let sheet = Sheet.landscapePhone
        let ordinary = artHeight(sheet)
        let accessible = artHeight(sheet, captionHeight: PlayableDetailLayout.defaultCaptionHeight * 2)
        XCTAssertLessThanOrEqual(accessible, ordinary)
    }
}
