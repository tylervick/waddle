import SwiftUI
import XCTest
@testable import Waddle

/// What a shelf tile is actually laid out against: the width one grid column
/// gets, and the shape and scrim that width implies. Written the same way as
/// `ShelfHeroLayoutTests` — over supplied bounds rather than a rendered screen,
/// because what matters is the relationship between the art, the tile and the
/// scrim, and that is arithmetic.
private enum TwoColumnPhone {
    /// iPhone 14 Pro/15/16 portrait: 393 pt wide, the geometry #199 was
    /// measured on. Less `ShelfView`'s 16 pt of padding on each side.
    static let width: CGFloat = 393
    static let contentPadding: CGFloat = 16
    static let gridSpacing: CGFloat = 16

    /// The width one tile gets here, derived rather than written out, so this
    /// stays true to whatever `Theme.gridMinimumTileWidth` resolves to: two
    /// columns of (393 − 32 − 16) / 2 = 172.5 pt.
    static var tileWidth: CGFloat {
        ShelfHeroLayout.gridColumnWidth(contentWidth: width - contentPadding * 2,
                                        minimum: Theme.gridMinimumTileWidth(for: .large),
                                        spacing: gridSpacing)
    }
}

final class PlayableTileLayoutTests: XCTestCase {

    // MARK: - The shape

    /// The decision, as geometry: a 172 pt tile is 129 pt tall, not the 229 pt
    /// that 3:4 made it. Restore `Theme.tileAspectRatio` to `3.0 / 4.0` and this
    /// is the first assertion that fails.
    func testTileIsFourByThree() {
        XCTAssertEqual(PlayableTileLayout.tileHeight(width: 172), 129, accuracy: 0.5)
        XCTAssertEqual(Theme.tileAspectRatio, 4.0 / 3.0, accuracy: 0.0001)
        // What it was, stated so the change is legible rather than implied.
        XCTAssertEqual(172 / (3.0 / 4.0), 229.33, accuracy: 0.5)
    }

    /// The same at the width the shelf actually hands a tile, so the 172 pt
    /// above is anchored to the real grid rather than asserted twice.
    func testTheTwoColumnPhoneTileIsThatShape() {
        XCTAssertEqual(TwoColumnPhone.tileWidth, 172.5, accuracy: 0.5)
        XCTAssertEqual(PlayableTileLayout.tileHeight(width: TwoColumnPhone.tileWidth),
                       129.4, accuracy: 0.5)
    }

    /// A zero or negative width is nonsense, not a reason to return a negative
    /// height — the same rule `PlayableDetailLayout` applies to its own width.
    func testNonPositiveWidthHasNoHeight() {
        XCTAssertEqual(PlayableTileLayout.tileHeight(width: 0), 0, accuracy: 0.001)
        XCTAssertEqual(PlayableTileLayout.tileHeight(width: -50), 0, accuracy: 0.001)
    }

    // MARK: - The scrim's share of it

    /// The ceiling, at the geometry it was set for: one line of title may cover
    /// at most 40% of the tile. Restore `scrimTopPadding` to 28 alone and this
    /// is the only assertion in this file that fails.
    func testScrimStaysUnderItsCeilingAtOneLine() {
        let share = PlayableTileLayout.scrimShare(tileWidth: TwoColumnPhone.tileWidth)
        XCTAssertLessThanOrEqual(share, PlayableTileLayout.maximumScrimShare,
                                 "scrim covers \(share * 100)% of the tile")
        // 16 + 22 + 10, and it has to be that sum rather than any 48 pt.
        XCTAssertEqual(PlayableTileLayout.scrimHeight(), 48, accuracy: 0.5)
    }

    /// What the ceiling is holding back, so the test above is not merely
    /// satisfied by arithmetic that could never have failed: the 28 pt top
    /// padding a portrait tile carried puts a one-line scrim at 47% of a 4:3
    /// tile — nearly half the card, which is the defect this budget exists for.
    func testTheOldTopPaddingWouldHaveExceededIt() {
        let oldScrim = 28 + PlayableTileLayout.defaultTitleLineHeight
            + PlayableTileLayout.scrimBottomPadding
        let oldShare = oldScrim / PlayableTileLayout.tileHeight(width: TwoColumnPhone.tileWidth)
        XCTAssertGreaterThan(oldShare, PlayableTileLayout.maximumScrimShare)
        XCTAssertEqual(oldShare, 0.46, accuracy: 0.02)
    }

    /// The scrim is the paddings plus the type, and nothing else — so a reader
    /// who changes either padding can see here what it costs.
    func testScrimIsItsPaddingsPlusOneLine() {
        XCTAssertEqual(PlayableTileLayout.scrimHeight(titleLineHeight: 30),
                       PlayableTileLayout.scrimTopPadding + 30
                           + PlayableTileLayout.scrimBottomPadding,
                       accuracy: 0.001)
    }

    /// A subtitle costs its own line and the gap above it. Unused on the shelf,
    /// which passes no subtitle, but `PlayableTileView` still draws one when it
    /// is given — and it must not be free in the budget.
    func testASubtitleAddsItsLineAndTheGap() {
        let withSubtitle = PlayableTileLayout.scrimHeight(subtitleLineHeight: 16)
        XCTAssertEqual(withSubtitle - PlayableTileLayout.scrimHeight(),
                       16 + PlayableTileLayout.titleSubtitleSpacing,
                       accuracy: 0.001)
    }

    /// Larger type raises the scrim, which is the case the ceiling cannot fix
    /// and is not asked to: the tile grows too at accessibility sizes, because
    /// `Theme.gridMinimumTileWidth` drops the grid to one column there.
    func testLargerTypeRaisesTheScrim() {
        XCTAssertGreaterThan(PlayableTileLayout.scrimHeight(titleLineHeight: 44),
                             PlayableTileLayout.scrimHeight())
    }

    // MARK: - What the art does in that shape

    /// The point of 4:3: it is the aspect Doom *displays* TITLEPIC at, so art at
    /// that aspect fills the tile with a scale factor of 1 in both axes and
    /// nothing is cropped.
    func testArtAtTheDisplayAspectIsNotCropped() {
        XCTAssertEqual(Theme.tileAspectRatio,
                       PlayableTileLayout.titlePicDisplayAspectRatio,
                       accuracy: 0.0001)
        XCTAssertEqual(PlayableTileLayout.visibleWidthFraction(
            sourceAspectRatio: PlayableTileLayout.titlePicDisplayAspectRatio,
            frameAspectRatio: Theme.tileAspectRatio), 1, accuracy: 0.0001)
        XCTAssertEqual(PlayableTileLayout.visibleHeightFraction(
            sourceAspectRatio: PlayableTileLayout.titlePicDisplayAspectRatio,
            frameAspectRatio: Theme.tileAspectRatio), 1, accuracy: 0.0001)
    }

    /// The defect this issue was raised for, kept as the thing that must not
    /// come back: a portrait tile showed 47% of TITLEPIC's width, and the
    /// fraction is the ratio of the two aspects, so it was identical at every
    /// tile size.
    func testThePortraitTileShowedLessThanHalfTheWidth() {
        let stored = PlayableTileLayout.titlePicStoredSize
        let sourceAspect = stored.width / stored.height
        XCTAssertEqual(PlayableTileLayout.visibleWidthFraction(sourceAspectRatio: sourceAspect,
                                                               frameAspectRatio: 3.0 / 4.0),
                       0.47, accuracy: 0.01)
        // And that 4:3 is what fixes it, rather than the tile merely being
        // smaller: at the same 3:4 the fraction is unchanged whatever the tile
        // measures, because it is a ratio of aspects and takes no size at all.
        XCTAssertLessThan(
            PlayableTileLayout.visibleWidthFraction(sourceAspectRatio: sourceAspect,
                                                    frameAspectRatio: 3.0 / 4.0),
            PlayableTileLayout.visibleWidthFraction(sourceAspectRatio: sourceAspect,
                                                    frameAspectRatio: Theme.tileAspectRatio))
    }

    /// What actually ships, stated rather than glossed: `TitleArtView` fills
    /// with TITLEPIC's **stored** 320 × 200 pixels, not with them corrected to
    /// 4:3, so the tile still crops the 8:5-to-4:3 difference — 83% of the width
    /// survives, against 47% before. Closing the last 17% means drawing the art
    /// aspect-corrected, which #199 ruled out by pinning `scaledToFill`.
    func testStoredPixelsStillGiveUpTheAspectCorrectionDifference() {
        let stored = PlayableTileLayout.titlePicStoredSize
        let sourceAspect = stored.width / stored.height
        XCTAssertEqual(sourceAspect, 8.0 / 5.0, accuracy: 0.0001)
        let visible = PlayableTileLayout.visibleWidthFraction(sourceAspectRatio: sourceAspect,
                                                              frameAspectRatio: Theme.tileAspectRatio)
        XCTAssertEqual(visible, 0.833, accuracy: 0.01)
        XCTAssertGreaterThan(visible,
                             PlayableTileLayout.visibleWidthFraction(sourceAspectRatio: sourceAspect,
                                                                     frameAspectRatio: 3.0 / 4.0))
    }

    /// Which axis gives depends on which way the mismatch runs, and both
    /// directions are pinned here because `TitleArtView` fills two different
    /// shapes: a square frame is *squarer* than 4:3 art, so the art overflows
    /// sideways and loses width; a 1.6:1 hero frame is wider than the same art,
    /// so it overflows downward and loses height instead.
    func testWhicheverAxisOverflowsIsTheOneThatIsCropped() {
        XCTAssertEqual(PlayableTileLayout.visibleWidthFraction(sourceAspectRatio: 4.0 / 3.0,
                                                               frameAspectRatio: 1.0),
                       0.75, accuracy: 0.0001)
        XCTAssertEqual(PlayableTileLayout.visibleHeightFraction(sourceAspectRatio: 4.0 / 3.0,
                                                                frameAspectRatio: 1.0),
                       1, accuracy: 0.0001)

        XCTAssertEqual(PlayableTileLayout.visibleWidthFraction(sourceAspectRatio: 4.0 / 3.0,
                                                               frameAspectRatio: Theme.heroAspectRatio),
                       1, accuracy: 0.0001)
        XCTAssertEqual(PlayableTileLayout.visibleHeightFraction(sourceAspectRatio: 4.0 / 3.0,
                                                                frameAspectRatio: Theme.heroAspectRatio),
                       0.833, accuracy: 0.001)
    }

    /// Nonsense aspects are not a reason to return a fraction that reads as
    /// "all of it".
    func testNonPositiveAspectsShowNothing() {
        XCTAssertEqual(PlayableTileLayout.visibleWidthFraction(sourceAspectRatio: 0,
                                                               frameAspectRatio: 1.33),
                       0, accuracy: 0.0001)
        XCTAssertEqual(PlayableTileLayout.visibleHeightFraction(sourceAspectRatio: 1.6,
                                                                frameAspectRatio: -1),
                       0, accuracy: 0.0001)
    }
}
