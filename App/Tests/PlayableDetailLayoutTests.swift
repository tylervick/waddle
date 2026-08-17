import XCTest
@testable import WADdle

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
    func testTileAspectRatioWouldNotHaveFit() {
        let sheet = Sheet.portraitPhone
        let tileShaped = sheet.contentWidth / Theme.tileAspectRatio
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
    /// `PlayableDetailView` measures this from `UIFont` instead of taking the
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
