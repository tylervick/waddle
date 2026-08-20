import SwiftUI
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

/// A supported device, described the way the shelf actually meets it: the
/// screen's point size, and the chrome above and below the scroll view.
///
/// The widths are not invented. They are every distinct iPhone width the
/// deployment target admits, read from the CoreSimulator device profiles
/// (`mainScreenWidth / mainScreenScale`) for the iOS 26 runtime — the same
/// source the `Viewport` figures above cite. `TARGETED_DEVICE_FAMILY` is
/// `"1,2"` and the target is iOS 26.0, and that runtime still lists the
/// iPhone 12 mini and 13 mini: **360 pt**, narrower than the 375 pt iPhone SE,
/// and the real floor this grid has to work at.
private struct SupportedDevice {
    let name: String
    let width: CGFloat
    let height: CGFloat
    /// Height the shelf never sees: the navigation bar, and the home
    /// indicator on the devices that have one.
    ///
    /// A large-title navigation bar is ~96 pt and the home indicator 34,
    /// hence 130 for everything with an indicator. The home-button SE has no
    /// indicator but does have a 20 pt status bar above the same bar, so 116.
    /// Both are the *taller* reading — an inline bar is nearer 44 — which
    /// makes every assertion below the harder version of itself.
    let chrome: CGFloat

    var contentWidth: CGFloat { width - ShelfLayoutFixture.contentPadding * 2 }
    var viewportHeight: CGFloat { height - chrome }

    /// `ui-tests.yml`'s `SIMULATOR_DEVICE`, and the widest phone the target
    /// admits. They are *different devices*, and conflating them is the
    /// mistake #204's measurement table made -- it reads "iPhone 17 Pro
    /// (440 x 956 pt)", which is the Pro Max's geometry under the Pro's name.
    /// Both are named here so no assertion below has to spell either out.
    static let uiTestsDestination = SupportedDevice(name: "iPhone 16 Pro/17/17 Pro",
                                                    width: 402, height: 874, chrome: 130)
    static let widestPhone = SupportedDevice(name: "iPhone 16/17 Pro Max",
                                             width: 440, height: 956, chrome: 130)

    static let allPhones: [SupportedDevice] = [
        // The floor, and the reason this list exists at all.
        SupportedDevice(name: "iPhone 12/13 mini", width: 360, height: 780, chrome: 130),
        SupportedDevice(name: "iPhone SE (2nd/3rd gen)", width: 375, height: 667, chrome: 116),
        SupportedDevice(name: "iPhone 11 Pro", width: 375, height: 812, chrome: 130),
        SupportedDevice(name: "iPhone 12/13/14/16e", width: 390, height: 844, chrome: 130),
        SupportedDevice(name: "iPhone 14 Pro/15/16", width: 393, height: 852, chrome: 130),
        uiTestsDestination,
        SupportedDevice(name: "iPhone 11/11 Pro Max", width: 414, height: 896, chrome: 130),
        SupportedDevice(name: "iPhone Air", width: 420, height: 912, chrome: 130),
        SupportedDevice(name: "iPhone 12/13/14 Pro Max", width: 428, height: 926, chrome: 130),
        SupportedDevice(name: "iPhone 14 Pro Max/15/16 Plus", width: 430, height: 932, chrome: 130),
        widestPhone,
    ]

    /// Distinct iPad point widths from the same runtime, portrait and
    /// landscape, smallest (iPad mini) to largest (13-inch landscape). Only
    /// the width matters here: iPad is in scope for not regressing the column
    /// count, not for the fold.
    static let padWidths: [CGFloat] = [744, 768, 810, 820, 834, 1024, 1032,
                                       1133, 1180, 1194, 1210, 1366, 1376]
}

/// The two `ShelfView` metrics the grid arithmetic is driven by, and a
/// default-size welcome card built from them.
///
/// `ShelfView` holds these as private computed properties, so they are
/// restated rather than reached into — the risk of them drifting apart is why
/// `contentPadding` and `gridSpacing` are named there instead of being inline
/// `.padding()` literals in the first place.
private enum ShelfLayoutFixture {
    static let contentPadding: CGFloat = 16
    static let gridSpacing: CGFloat = 16

    /// The card's rows at the default text size, rounded from the `UIFont`
    /// line heights `ShelfView` measures: `.title1` for the app name, two
    /// wrapped `.subheadline` lines for the description, and the button at its
    /// 44 pt tap-target floor.
    ///
    /// Passed as explicit numbers, not read from `UIFont`, for the reason the
    /// rest of this file supplies bounds rather than rendering a screen: the
    /// real ones follow whatever Dynamic Type setting the simulator happens to
    /// be in, and a test that changes answer with a device setting proves
    /// nothing.
    /// The same three numbers `defaultSizeCard` below uses, kept identical on
    /// purpose: two fixtures for one card would drift.
    static let titleHeight: CGFloat = 41
    static let descriptionHeight: CGFloat = 40
    static let buttonHeight: CGFloat = 44

    static var fullCardHeight: CGFloat {
        ShelfHeroLayout.welcomeCardHeight(titleHeight: titleHeight,
                                          descriptionHeight: descriptionHeight,
                                          buttonHeight: buttonHeight)
    }

    /// The card without its description — the smallest form the zone has.
    static var compactCardHeight: CGFloat {
        ShelfHeroLayout.welcomeCardHeight(titleHeight: titleHeight,
                                          descriptionHeight: 0,
                                          buttonHeight: buttonHeight)
    }
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

    // MARK: The welcome card's budget (spec §4)

    /// The phone `ui-tests.yml` runs `EngineSmokeTests` on, which is where
    /// the flaky tap was observed: `SIMULATOR_DEVICE` is `iPhone 17 Pro`, so
    /// 402 x 874 pt less the padding and chrome `SupportedDevice` models.
    ///
    /// Taken from that type rather than written out, because the previous
    /// spelling of it -- 408 pt of content, i.e. a 440 pt device -- carried
    /// #204's Pro/Pro Max mix-up into the fixture and made this the *widest*
    /// phone while calling it the CI one. The two cases are separate below,
    /// each under its own name.
    private let ciPhone = SupportedDevice.uiTestsDestination
    private let widestPhone = SupportedDevice.widestPhone

    /// The card at the default text size: `.title` over a two-line
    /// `.subheadline` over the 44 pt button.
    private var defaultSizeCard: CGFloat {
        ShelfHeroLayout.welcomeCardHeight(titleHeight: 41,
                                          descriptionHeight: 40,
                                          buttonHeight: 44)
    }

    /// The same card at an accessibility text size, where every row grows.
    private var accessibilitySizeCard: CGFloat {
        ShelfHeroLayout.welcomeCardHeight(titleHeight: 68,
                                          descriptionHeight: 172,
                                          buttonHeight: 76)
    }

    func testAdaptiveColumnWidthMatchesASingleFullWidthColumn() {
        // Even the widest phone's 408 pt of content cannot fit two 200 pt
        // columns plus a 16 pt gap, so the grid resolved to one column
        // spanning the whole width -- which is what made the first tile row
        // 544 pt tall there.
        XCTAssertEqual(ShelfHeroLayout.gridColumnWidth(contentWidth: widestPhone.contentWidth,
                                                       minimum: 200,
                                                       spacing: 16), 408)
    }

    func testAdaptiveColumnWidthSplitsWhenTwoFit() {
        XCTAssertEqual(ShelfHeroLayout.gridColumnWidth(contentWidth: widestPhone.contentWidth,
                                                       minimum: 190,
                                                       spacing: 16), 196)
    }

    func testAdaptiveColumnWidthIsZeroBeforeMeasurement() {
        XCTAssertEqual(ShelfHeroLayout.gridColumnWidth(contentWidth: 0,
                                                       minimum: 200,
                                                       spacing: 16), 0)
    }

    func testCompactCardIsShorterThanTheFullOne() {
        let compact = ShelfHeroLayout.welcomeCardHeight(titleHeight: 41,
                                                        descriptionHeight: 0,
                                                        buttonHeight: 44)
        XCTAssertLessThan(compact, defaultSizeCard)
        // One row and one gap gone, nothing else.
        XCTAssertEqual(defaultSizeCard - compact,
                       40 + ShelfHeroLayout.welcomeCardRowSpacing)
    }

    /// The regression this budget exists for: on the phone CI runs, the full
    /// card does not fit above the first tile row, and saying it does is what
    /// left `playFreedoom1` present, on screen, and impossible to activate.
    func testWelcomeCardDropsItsDescriptionOnTheCIPhone() {
        XCTAssertFalse(ShelfHeroLayout.welcomeCardShowsDescription(
            viewportHeight: ciPhone.viewportHeight,
            contentWidth: ciPhone.contentWidth,
            tileMinimumWidth: 200,
            contentPadding: 16,
            gridSpacing: 16,
            fullCardHeight: defaultSizeCard))
    }

    /// The compact card must actually solve it -- a budget that both forms
    /// fail is a cap that only looks like one.
    func testCompactWelcomeCardLeavesTheFirstRowAboveTheFold() {
        let compact = ShelfHeroLayout.welcomeCardHeight(titleHeight: 41,
                                                        descriptionHeight: 0,
                                                        buttonHeight: 44)
        XCTAssertLessThanOrEqual(
            compact,
            ShelfHeroLayout.heroZoneBudget(viewportHeight: ciPhone.viewportHeight,
                                           contentWidth: ciPhone.contentWidth,
                                           tileMinimumWidth: 200,
                                           contentPadding: 16,
                                           gridSpacing: 16))
    }

    /// And the full card must be shown wherever it does fit: this is a cap,
    /// not a demotion.
    func testWelcomeCardKeepsItsDescriptionOnARoomyViewport() {
        XCTAssertTrue(ShelfHeroLayout.welcomeCardShowsDescription(
            viewportHeight: 1200,
            contentWidth: ciPhone.contentWidth,
            tileMinimumWidth: 200,
            contentPadding: 16,
            gridSpacing: 16,
            fullCardHeight: defaultSizeCard))
    }

    /// An unmeasured viewport must not flash a compact card on the first
    /// frame, matching how `artHeight` treats the same state.
    func testWelcomeCardKeepsItsDescriptionBeforeTheViewportIsMeasured() {
        XCTAssertTrue(ShelfHeroLayout.welcomeCardShowsDescription(
            viewportHeight: 0,
            contentWidth: 0,
            tileMinimumWidth: 200,
            contentPadding: 16,
            gridSpacing: 16,
            fullCardHeight: defaultSizeCard))
    }

    /// The accessibility case, which a budget written against default-size
    /// constants gets wrong in the dangerous direction: the card grows, the
    /// adaptive minimum grows with it, and a fixed 184 pt would have cleared a
    /// card more than twice that tall.
    func testWelcomeCardDropsItsDescriptionAtAccessibilitySizes() {
        XCTAssertGreaterThan(accessibilitySizeCard, defaultSizeCard * 1.5)
        XCTAssertFalse(ShelfHeroLayout.welcomeCardShowsDescription(
            viewportHeight: ciPhone.viewportHeight,
            contentWidth: ciPhone.contentWidth,
            tileMinimumWidth: 320,
            contentPadding: 16,
            gridSpacing: 16,
            fullCardHeight: accessibilitySizeCard))
    }

    /// A roomy viewport keeps the full card at accessibility sizes too --
    /// the rule is the arithmetic, not "accessibility means compact".
    func testWelcomeCardKeepsItsDescriptionAtAccessibilitySizesWhenItFits() {
        XCTAssertTrue(ShelfHeroLayout.welcomeCardShowsDescription(
            viewportHeight: 1600,
            contentWidth: ciPhone.contentWidth,
            tileMinimumWidth: 320,
            contentPadding: 16,
            gridSpacing: 16,
            fullCardHeight: accessibilitySizeCard))
    }

    // MARK: - How many columns the shelf resolves to

    private func standardColumns(_ contentWidth: CGFloat) -> Int {
        ShelfHeroLayout.gridColumnCount(
            contentWidth: contentWidth,
            minimum: Theme.gridMinimumTileWidth(for: .large),
            spacing: ShelfLayoutFixture.gridSpacing)
    }

    /// The defect, stated as the thing that actually caused it: a 200 pt floor
    /// resolved to **one** column on every iPhone the deployment target
    /// admits -- not just narrow ones -- which is what made the first tile row
    /// 3:4 of the entire content width and pushed its bottom past the fold.
    ///
    /// Put `Theme.gridMinimumTileWidth(for:)`'s standard branch back to 200
    /// and this is the assertion that fails, on all eleven widths.
    func testEverySupportedPhoneWidthGetsTwoColumns() {
        for device in SupportedDevice.allPhones {
            XCTAssertEqual(standardColumns(device.contentWidth), 2,
                           "\(device.name) at \(device.width) pt")
        }
    }

    /// Two, and not more: the floor is also what stops a wide phone from
    /// slicing the shelf into tiles too small to read the art on. Pinning both
    /// ends means a future change in either direction has to say so.
    func testNoSupportedPhoneWidthGetsThreeColumns() {
        for device in SupportedDevice.allPhones {
            XCTAssertLessThanOrEqual(standardColumns(device.contentWidth), 2,
                                     "\(device.name) at \(device.width) pt")
        }
    }

    /// 360 pt is the floor, and it is not the iPhone SE. The iOS 26 runtime
    /// still lists the 12 mini and 13 mini, so a floor derived from the 375 pt
    /// SE -- or from the 440 pt widest phone, which is the geometry #204's
    /// measurements were taken at -- would be derived from the wrong device.
    func testTheNarrowestSupportedWidthIsWhatTheFloorIsDerivedFrom() {
        let narrowest = SupportedDevice.allPhones.map(\.width).min()
        XCTAssertEqual(narrowest, 360)

        // Two columns at that width need a floor of at most
        // (360 - 32 - 16) / 2 = 156 pt.
        let narrowestContent: CGFloat = 360 - ShelfLayoutFixture.contentPadding * 2
        let widest = (narrowestContent - ShelfLayoutFixture.gridSpacing) / 2
        XCTAssertEqual(widest, 156)
        XCTAssertLessThanOrEqual(Theme.gridMinimumTileWidth(for: .large), widest)
    }

    /// And strictly below it, not on it. 156 pt is the exact boundary, where
    /// the adaptive fit evaluates to precisely 2.0 columns; a layout decision
    /// balanced on an equality is the shape of defect this whole issue is, so
    /// the constant has to sit clear of it. Shaving 8 pt off the narrowest
    /// content width must still leave two columns.
    func testTheFloorIsNotBalancedOnTheTwoColumnBoundary() {
        let narrowestContent: CGFloat = 360 - ShelfLayoutFixture.contentPadding * 2
        XCTAssertLessThan(Theme.gridMinimumTileWidth(for: .large), 156)
        XCTAssertEqual(standardColumns(narrowestContent - 8), 2)
    }

    /// Every standard size, not just `.large`: the floor does not vary across
    /// them, and this is what says so rather than assuming it.
    func testEveryStandardDynamicTypeSizeGetsTwoColumnsAtTheNarrowestWidth() {
        let narrowestContent: CGFloat = 360 - ShelfLayoutFixture.contentPadding * 2
        for size in DynamicTypeSize.allCases where !size.isAccessibilitySize {
            let columns = ShelfHeroLayout.gridColumnCount(
                contentWidth: narrowestContent,
                minimum: Theme.gridMinimumTileWidth(for: size),
                spacing: ShelfLayoutFixture.gridSpacing)
            XCTAssertEqual(columns, 2, "\(size)")
        }
    }

    /// Accessibility sizes are the documented exception and stay at one
    /// column -- spec §5's "drops columns rather than shrinking text". A lower
    /// standard floor must not drag the accessibility floor down with it.
    func testAccessibilitySizesKeepOneColumnOnEverySupportedPhone() {
        for device in SupportedDevice.allPhones {
            let columns = ShelfHeroLayout.gridColumnCount(
                contentWidth: device.contentWidth,
                minimum: Theme.gridMinimumTileWidth(for: .accessibility3),
                spacing: ShelfLayoutFixture.gridSpacing)
            XCTAssertEqual(columns, 1, "\(device.name)")
        }
    }

    /// What two columns are *for*: the first row is roughly half as tall, so
    /// the hero zone has somewhere to live. Stated as a ratio rather than a
    /// height, since it holds at every width.
    func testTwoColumnsHalveTheFirstTileRowHeight() {
        for device in SupportedDevice.allPhones {
            let oneColumn = device.contentWidth / Theme.tileAspectRatio
            let actual = ShelfHeroLayout.gridColumnWidth(
                contentWidth: device.contentWidth,
                minimum: Theme.gridMinimumTileWidth(for: .large),
                spacing: ShelfLayoutFixture.gridSpacing) / Theme.tileAspectRatio
            XCTAssertLessThan(actual, oneColumn * 0.55, "\(device.name)")
        }
    }

    // MARK: - The margin between the first tile row and the fold

    /// Constructs the viewport height that yields exactly `budget` of hero
    /// zone at this width, so the boundary tests below can sit a known
    /// distance either side of the requirement instead of hunting for it.
    private func viewportHeight(forBudget budget: CGFloat,
                                contentWidth: CGFloat,
                                minimum: CGFloat) -> CGFloat {
        let rowHeight = ShelfHeroLayout.gridColumnWidth(
            contentWidth: contentWidth,
            minimum: minimum,
            spacing: ShelfLayoutFixture.gridSpacing) / Theme.tileAspectRatio
        return budget + ShelfLayoutFixture.contentPadding * 2
            + ShelfHeroLayout.sectionSpacing + rowHeight
    }

    private func showsDescription(budget: CGFloat,
                                  cardHeight: CGFloat,
                                  contentWidth: CGFloat = SupportedDevice.widestPhone.contentWidth,
                                  minimum: CGFloat = 150) -> Bool {
        ShelfHeroLayout.welcomeCardShowsDescription(
            viewportHeight: viewportHeight(forBudget: budget,
                                           contentWidth: contentWidth,
                                           minimum: minimum),
            contentWidth: contentWidth,
            tileMinimumWidth: minimum,
            contentPadding: ShelfLayoutFixture.contentPadding,
            gridSpacing: ShelfLayoutFixture.gridSpacing,
            fullCardHeight: cardHeight)
    }

    /// The second half of the defect, and the one a column count alone does
    /// not reach: a hero zone used to be accepted when the first tile row
    /// ended *exactly* on the fold. On the geometry #204 measured that left
    /// about 16 pt of slack, which is how a layout that measured as fitting
    /// still produced a tap that synthesized cleanly and activated nothing.
    ///
    /// Set `ShelfHeroLayout.minimumFoldClearance` to 0 and this is the
    /// assertion that fails: 16 pt of margin goes back to counting as a fit.
    func testAZoneThatOnlyJustFitsIsRejected() {
        let card = ShelfLayoutFixture.fullCardHeight
        XCTAssertFalse(showsDescription(budget: card + 16, cardHeight: card))
    }

    /// Not merely "reject everything": the requirement is a specific distance,
    /// and one clearance past the card is enough to earn the description back.
    ///
    /// A point *over* the clearance rather than exactly on it, and the
    /// companion below sits a point under: the two together pin the boundary
    /// to within 2 pt without asserting on an equality. A tile row is
    /// 261.33 pt at the widest phone's 408 pt of content, which no binary
    /// float holds exactly, so a test written on the boundary itself would be
    /// measuring `Double`'s rounding rather than this type's rule -- and would
    /// fail, as the first draft of it did.
    func testAZoneWithTheClearanceIsAccepted() {
        let card = ShelfLayoutFixture.fullCardHeight
        XCTAssertTrue(showsDescription(
            budget: card + ShelfHeroLayout.minimumFoldClearance + 1, cardHeight: card))
    }

    /// A point short of it is not.
    func testAZoneAPointShortOfTheClearanceIsRejected() {
        let card = ShelfLayoutFixture.fullCardHeight
        XCTAssertFalse(showsDescription(
            budget: card + ShelfHeroLayout.minimumFoldClearance - 1, cardHeight: card))
    }

    /// The clearance is a real distance, and one anchored to something rather
    /// than picked: spec §5's minimum tap target, because the row has to be
    /// tappable without scrolling and not merely visible.
    func testTheClearanceIsOneMinimumTapTarget() {
        XCTAssertEqual(ShelfHeroLayout.minimumFoldClearance, Theme.minimumTapTarget)
        XCTAssertGreaterThan(ShelfHeroLayout.minimumFoldClearance, 16)
    }

    /// The two halves together, on real devices: with two columns the *full*
    /// card -- description and all -- clears the fold by more than the
    /// required margin on every supported iPhone, so nothing has to be
    /// dropped to make the shelf tappable.
    ///
    /// This is the assertion that fails at the narrow end if the floor goes
    /// back to 200: the 360 pt mini's single column leaves the zone 24 pt in
    /// deficit before the card is even placed.
    func testEverySupportedPhoneClearsTheFoldWithTheFullCard() {
        let card = ShelfLayoutFixture.fullCardHeight
        for device in SupportedDevice.allPhones {
            let budget = ShelfHeroLayout.heroZoneBudget(
                viewportHeight: device.viewportHeight,
                contentWidth: device.contentWidth,
                tileMinimumWidth: Theme.gridMinimumTileWidth(for: .large),
                contentPadding: ShelfLayoutFixture.contentPadding,
                gridSpacing: ShelfLayoutFixture.gridSpacing)
            XCTAssertGreaterThanOrEqual(budget - card,
                                        ShelfHeroLayout.minimumFoldClearance,
                                        "\(device.name) at \(device.width) pt")
            XCTAssertTrue(ShelfHeroLayout.welcomeCardShowsDescription(
                viewportHeight: device.viewportHeight,
                contentWidth: device.contentWidth,
                tileMinimumWidth: Theme.gridMinimumTileWidth(for: .large),
                contentPadding: ShelfLayoutFixture.contentPadding,
                gridSpacing: ShelfLayoutFixture.gridSpacing,
                fullCardHeight: card), "\(device.name)")
        }
    }

    /// The compact card is what the zone falls back to, so it has to clear the
    /// fold by at least as much again -- otherwise dropping the description
    /// buys nothing, which was PR #203's actual result.
    func testTheCompactCardClearsTheFoldOnEverySupportedPhone() {
        for device in SupportedDevice.allPhones {
            let budget = ShelfHeroLayout.heroZoneBudget(
                viewportHeight: device.viewportHeight,
                contentWidth: device.contentWidth,
                tileMinimumWidth: Theme.gridMinimumTileWidth(for: .large),
                contentPadding: ShelfLayoutFixture.contentPadding,
                gridSpacing: ShelfLayoutFixture.gridSpacing)
            XCTAssertGreaterThanOrEqual(budget - ShelfLayoutFixture.compactCardHeight,
                                        ShelfHeroLayout.minimumFoldClearance,
                                        "\(device.name) at \(device.width) pt")
        }
    }

    /// At an accessibility size the shelf goes back to one column by design,
    /// and the zone is genuinely tight -- this pins which way it gives. The
    /// description goes, exactly as `welcomeCardShowsDescription` documents,
    /// rather than the row being declared to fit.
    func testAccessibilitySizeDropsTheDescriptionAtTheNarrowestWidth() {
        let device = SupportedDevice.allPhones[0]
        XCTAssertEqual(device.width, 360)
        XCTAssertFalse(ShelfHeroLayout.welcomeCardShowsDescription(
            viewportHeight: device.viewportHeight,
            contentWidth: device.contentWidth,
            tileMinimumWidth: Theme.gridMinimumTileWidth(for: .accessibility3),
            contentPadding: ShelfLayoutFixture.contentPadding,
            gridSpacing: ShelfLayoutFixture.gridSpacing,
            fullCardHeight: accessibilitySizeCard))
    }

    // MARK: - iPad

    /// Lowering the floor adds columns on iPad too, and this says what they
    /// become rather than leaving it to be discovered. `TARGETED_DEVICE_FAMILY`
    /// is `"1,2"` and `mise run test` runs an iPad destination, so this is a
    /// supported surface and not a side effect.
    ///
    /// The counts land between 4 (iPad mini portrait) and 8 (13-inch
    /// landscape), where they used to be 3 to 6.
    func testIPadColumnCountsAreStated() {
        let expected: [CGFloat: Int] = [744: 4, 768: 4, 810: 4, 820: 4, 834: 4,
                                        1024: 6, 1032: 6, 1133: 6, 1180: 7,
                                        1194: 7, 1210: 7, 1366: 8, 1376: 8]
        for width in SupportedDevice.padWidths {
            let content = width - ShelfLayoutFixture.contentPadding * 2
            XCTAssertEqual(standardColumns(content), expected[width], "\(width) pt")
        }
    }

    /// And that they stay sane. "Sane" is stated as a band rather than a
    /// feeling: an iPad tile lands between 150 and 190 pt, against 156 to
    /// 196 pt on a phone. The shelf trades iPad's oversized 207-257 pt tiles
    /// for tiles about the size of a phone's, which is a consistent shelf
    /// rather than a shrunken one -- and on a 13-inch iPad, 154 pt is still
    /// physically larger than the 156 pt tile on a mini, because the points
    /// are further apart.
    func testIPadTilesStayInTheSameSizeBandAsPhoneTiles() {
        for width in SupportedDevice.padWidths {
            let tile = ShelfHeroLayout.gridColumnWidth(
                contentWidth: width - ShelfLayoutFixture.contentPadding * 2,
                minimum: Theme.gridMinimumTileWidth(for: .large),
                spacing: ShelfLayoutFixture.gridSpacing)
            XCTAssertGreaterThanOrEqual(tile, 150, "\(width) pt")
            XCTAssertLessThanOrEqual(tile, 190, "\(width) pt")
        }
    }
}
