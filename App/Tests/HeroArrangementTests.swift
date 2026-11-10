import SwiftUI
import XCTest
@testable import Waddle

/// Issue #371: which way the Continue hero is arranged, decided from the
/// window it is in rather than from the height class alone.
///
/// The rule is `ShelfHeroLayout.arrangement(compactHeight:contentWidth:
/// stackedArtHeight:)`. These cases hand it each shape the shelf is known to
/// meet and check the answer. As ever with this layout, arithmetic cannot see
/// the screen (`docs/learnings/geometry-tests-cannot-see-the-screen.md`); the
/// look was checked on the simulator and is in the pull request.
final class HeroArrangementTests: XCTestCase {

    private static let spacing: CGFloat = 20
    private static let padding: CGFloat = 16

    /// The open iPhone Duo as the shelf measures it: 951 pt wide less the
    /// 84 pt status column and the padding, and the 555 pt viewport its
    /// 343 pt art cap implied in build 285 (343 + 60 + 32 + 120).
    private static let duoOpen = Viewport(contentWidth: 835, height: 555)
    /// The open Duo rotated, 669x951 pt. The bar is on top in this pose; the
    /// viewport height is an estimate (the window less about 100 pt of bar
    /// and indicator), and the case does not turn on it.
    private static let duoOpenRotated = Viewport(contentWidth: 637, height: 850)
    /// The closed Duo in portrait: 344 pt of content, measured. The height
    /// is an estimate; a window this narrow stacks whatever it is.
    private static let duoClosed = Viewport(contentWidth: 344, height: 620)
    /// An 11-inch iPad in landscape, 1194x834 pt, with the same chrome
    /// subtractions `Viewport.landscapePad` uses for the 13-inch.
    private static let landscapePad11 = Viewport(contentWidth: 1194 - 32, height: 834 - 96 - 20)

    /// The stacked art's height in `viewport`, exactly as `ShelfView` asks
    /// for it: capped so the whole first tile row stays above the fold on a
    /// wide window.
    private func stackedArtHeight(_ viewport: Viewport) -> CGFloat {
        let minimum = Theme.gridMinimumTileWidth(for: .large, contentWidth: viewport.contentWidth)
        return ShelfHeroLayout.artHeight(
            contentWidth: viewport.contentWidth,
            viewportHeight: viewport.height,
            gridPeek: ShelfHeroLayout.gridPeek(contentWidth: viewport.contentWidth,
                                               tileMinimumWidth: minimum,
                                               gridSpacing: Self.spacing,
                                               contentPadding: Self.padding))
    }

    private func arrangement(_ viewport: Viewport, compactHeight: Bool = false) -> ShelfHeroLayout.Arrangement {
        ShelfHeroLayout.arrangement(compactHeight: compactHeight,
                                    contentWidth: viewport.contentWidth,
                                    stackedArtHeight: stackedArtHeight(viewport))
    }

    /// The share of the row the stacked art would cover at its own shape.
    private func fill(_ viewport: Viewport) -> CGFloat {
        stackedArtHeight(viewport) * Theme.heroAspectRatio / viewport.contentWidth
    }

    // MARK: The case this exists for

    /// On the open Duo the stacked art is a banner it cannot fill: capped to
    /// 286 pt it is 458 pt of art in an 835 pt row. So it goes beside its
    /// caption.
    func testTheOpenDuoPutsTheArtBesideItsCaption() {
        XCTAssertLessThan(fill(Self.duoOpen), 0.6)
        XCTAssertEqual(arrangement(Self.duoOpen), .sideBySide)
    }

    /// The discrimination: the rule this replaced asked only for the height
    /// class, and the open Duo is regular height, so it stacked.
    func testTheHeightClassAloneStackedTheOpenDuo() {
        XCTAssertEqual(ShelfHeroLayout.arrangement(compactHeight: false), .stacked)
    }

    /// Beside its caption the art is whole, takes at most half the row, and
    /// leaves the entire first tile row above the fold.
    func testSideBySideOnTheOpenDuoLeavesTheFirstRowAboveTheFold() {
        let viewport = Self.duoOpen
        let art = ShelfHeroLayout.sideBySideArtHeight(contentWidth: viewport.contentWidth,
                                                      viewportHeight: viewport.height)
        let width = ShelfHeroLayout.sideBySideArtWidth(contentWidth: viewport.contentWidth,
                                                       viewportHeight: viewport.height)
        XCTAssertEqual(width / art, Theme.heroAspectRatio, accuracy: 0.001, "the art is not whole")
        XCTAssertLessThanOrEqual(width, viewport.contentWidth / 2)

        let minimum = Theme.gridMinimumTileWidth(for: .large, contentWidth: viewport.contentWidth)
        let rowHeight = ShelfHeroLayout.gridColumnWidth(contentWidth: viewport.contentWidth,
                                                        minimum: minimum,
                                                        spacing: Self.spacing) / Theme.tileAspectRatio
        XCTAssertLessThanOrEqual(Self.padding + art + ShelfHeroLayout.sectionSpacing + rowHeight,
                                 viewport.height, "the first tile row ends below the fold")
    }

    // MARK: What must not move

    /// A window that is not wide stacks, whatever the cap has done to its
    /// art: a phone in portrait, and the closed Duo.
    func testNarrowWindowsStack() {
        for viewport in [Viewport.portraitPhone, Self.duoClosed] {
            XCTAssertLessThan(viewport.contentWidth, Theme.wideGridContentWidth)
            XCTAssertEqual(arrangement(viewport), .stacked, "\(viewport.contentWidth) wide")
        }
        // Even with its art crushed to the floor, a narrow window does not flip.
        XCTAssertEqual(ShelfHeroLayout.arrangement(compactHeight: false,
                                                   contentWidth: Viewport.portraitPhone.contentWidth,
                                                   stackedArtHeight: ShelfHeroLayout.minimumArtHeight),
                       .stacked)
    }

    /// The open Duo rotated is wide and tall: its art fits at its natural
    /// height, fills the row, and stacks.
    func testTheOpenRotatedDuoStacks() {
        XCTAssertEqual(fill(Self.duoOpenRotated), 1, accuracy: 0.001)
        XCTAssertEqual(arrangement(Self.duoOpenRotated), .stacked)
    }

    /// A 13-inch iPad keeps the stacked hero in both orientations. In
    /// landscape that is the decision `ShelfHeroLayoutTests` records ("capped
    /// but still dominant"), and it sits clear of the threshold, not on it.
    func testThe13InchPadStaysStackedInBothOrientations() {
        XCTAssertEqual(arrangement(Viewport.portraitPad), .stacked)
        XCTAssertEqual(arrangement(Viewport.landscapePad), .stacked)
        XCTAssertGreaterThan(fill(Viewport.landscapePad), ShelfHeroLayout.minimumStackedArtFill + 0.05)
    }

    /// Compact height is side by side whatever the widths say: the landscape
    /// phone the arrangement was first made for.
    func testCompactHeightIsSideBySide() {
        for viewport in [Viewport.landscapePhone, Viewport.landscapeProPhone] {
            XCTAssertEqual(arrangement(viewport, compactHeight: true), .sideBySide)
        }
    }

    /// Before the shelf has measured itself the widths are zero, which is
    /// not a wide window.
    func testAnUnmeasuredShelfStacks() {
        XCTAssertEqual(ShelfHeroLayout.arrangement(compactHeight: false, contentWidth: 0,
                                                   stackedArtHeight: 0), .stacked)
    }

    // MARK: What follows from the rule

    /// The rule is about the window, not the device, so it has a consequence
    /// nobody has looked at on a simulator yet: an 11-inch iPad in landscape
    /// is shallow enough that its stacked art would cover about 61% of the
    /// row, and it goes side by side too. Recorded here so the day someone
    /// does look, the arithmetic is already written down.
    func testAnElevenInchPadInLandscapeGoesSideBySide() {
        XCTAssertLessThan(fill(Self.landscapePad11), ShelfHeroLayout.minimumStackedArtFill)
        XCTAssertEqual(arrangement(Self.landscapePad11), .sideBySide)
    }

    /// The two cases the threshold has to tell apart are on opposite sides
    /// of it with room to spare.
    func testTheThresholdSeparatesTheDuoFromThe13InchPad() {
        XCTAssertLessThan(fill(Self.duoOpen), ShelfHeroLayout.minimumStackedArtFill - 0.05)
        XCTAssertGreaterThan(fill(Viewport.landscapePad), ShelfHeroLayout.minimumStackedArtFill + 0.05)
    }
}
