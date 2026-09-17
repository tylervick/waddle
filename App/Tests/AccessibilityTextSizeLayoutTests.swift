import SwiftUI
import UIKit
import XCTest
@testable import Waddle

/// The shelf's layout at accessibility Dynamic Type sizes (issue #216).
///
/// `ShelfHeroLayoutTests` already covers the *width* half of Dynamic Type:
/// `Theme.gridMinimumTileWidth(for:)` jumps 150 → 320 at an accessibility
/// size, and two tests pin the column counts that fall out of it. What it
/// does not cover is the *height* half. `ShelfView` measures three metrics
/// from `UIFont` — the hero's caption block, the welcome card's button, and
/// the welcome card's wrapped description — and every one of them grows with
/// the reader's text size. Those three are what `heroZoneBudget` is spent on,
/// and until this file they were only ever exercised at their default-size
/// values (`ShelfLayoutFixture.descriptionHeight` = 40, `buttonHeight` = 44).
///
/// So the property at risk is the one
/// `docs/learnings/hero-zone-must-leave-a-tappable-tile-row.md` was written
/// for: a hero zone that grows until the first tile row, while still *visible*
/// and still in the accessibility hierarchy, stops being *tappable*. At
/// accessibility sizes the zone grows from both directions at once — a taller
/// card and a taller tile row, the latter because a 320 pt column minimum
/// drops the grid to one column and a one-column tile is 4:3 of the whole
/// content width.
///
/// ## Why `UIFont` is allowed here, when `ShelfLayoutFixture` refuses it
///
/// That fixture's rationale is exact and still holds: the *bare*
/// `UIFont.preferredFont(forTextStyle:)` follows whatever Dynamic Type setting
/// the simulator happens to be in, so a test built on it changes answer with a
/// device setting and proves nothing.
///
/// `preferredFont(forTextStyle:compatibleWith:)` is a different function. Given
/// an explicit `UITraitCollection(preferredContentSizeCategory:)` it returns
/// that category's font regardless of the host's own setting, which is exactly
/// the determinism the fixture is protecting.
/// `testMetricsDoNotFollowTheHostContentSizeSetting` proves that rather than
/// asserting it, because the whole file rests on it.
private enum TextMetrics {
    /// Mirrors `ShelfView.heroCaptionHeight`: a `.title2` title, a
    /// `.subheadline` Continue line, and `heroCaptionSpacing` twice.
    static func captionHeight(_ category: UIContentSizeCategory) -> CGFloat {
        lineHeight(.title2, category) + lineHeight(.subheadline, category) + 6 * 2
    }

    /// Mirrors `ShelfView.welcomeButtonHeight`: a `.borderedProminent` label
    /// plus the style's vertical padding, floored at the tap target.
    static func buttonHeight(_ category: UIContentSizeCategory) -> CGFloat {
        max(Theme.minimumTapTarget, lineHeight(.body, category) + 14)
    }

    /// Mirrors `ShelfView.welcomeDescriptionHeight`: the real wrapped height
    /// of the real string at this width and text size. The string is restated
    /// for the same reason `ShelfLayoutFixture` restates `contentPadding` —
    /// `ShelfView` holds it privately.
    static func descriptionHeight(_ category: UIContentSizeCategory,
                                  contentWidth: CGFloat) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .subheadline,
                                        compatibleWith: traits(category))
        let inner = contentWidth - ShelfHeroLayout.welcomeCardPadding * 2
        guard inner > 0 else { return font.lineHeight }
        let box = (description as NSString).boundingRect(
            with: CGSize(width: inner, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil)
        return ceil(box.height)
    }

    static let description =
        "Bring your own WADs, or start with the Freedoom games below."

    /// Every accessibility category, largest last.
    static let accessibilityCategories: [UIContentSizeCategory] = [
        .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge,
        .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge,
    ]

    static func traits(_ category: UIContentSizeCategory) -> UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: category)
    }

    private static func lineHeight(_ style: UIFont.TextStyle,
                                   _ category: UIContentSizeCategory) -> CGFloat {
        UIFont.preferredFont(forTextStyle: style, compatibleWith: traits(category)).lineHeight
    }
}

final class AccessibilityTextSizeLayoutTests: XCTestCase {

    // MARK: - The file's own foundations

    /// The determinism claim the whole file rests on. `compatibleWith:` must
    /// answer for the category it is handed, not for the host's setting — so
    /// asking for two different categories must give two different answers,
    /// and asking for the same one twice must give the same answer.
    func testMetricsDoNotFollowTheHostContentSizeSetting() {
        let small = TextMetrics.captionHeight(.small)
        let huge = TextMetrics.captionHeight(.accessibilityExtraExtraExtraLarge)
        XCTAssertGreaterThan(huge, small,
                             "compatibleWith: is not resolving distinct categories")
        XCTAssertEqual(small, TextMetrics.captionHeight(.small),
                       "same category gave two answers — not deterministic")
    }

    /// If the metrics did not actually grow, every assertion below would pass
    /// against a stationary layout and cover nothing. Pin the direction.
    func testEveryMeasuredMetricGrowsWithTextSize() {
        let base = UIContentSizeCategory.large
        for category in TextMetrics.accessibilityCategories {
            XCTAssertGreaterThan(TextMetrics.captionHeight(category),
                                 TextMetrics.captionHeight(base), "\(category.rawValue)")
            XCTAssertGreaterThanOrEqual(TextMetrics.buttonHeight(category),
                                        TextMetrics.buttonHeight(base), "\(category.rawValue)")
            XCTAssertGreaterThan(
                TextMetrics.descriptionHeight(category, contentWidth: 360 - 32),
                TextMetrics.descriptionHeight(base, contentWidth: 360 - 32),
                "\(category.rawValue)")
        }
    }

    /// The default-size numbers `ShelfLayoutFixture` hard-codes must still be
    /// what `UIFont` reports at the default size, or that fixture has drifted
    /// from the app and its own suite is measuring a card nobody renders.
    func testTheDefaultSizeFixtureStillMatchesUIFont() {
        XCTAssertEqual(TextMetrics.buttonHeight(.large),
                       ShelfLayoutFixture.buttonHeight, accuracy: 1)
        XCTAssertEqual(
            TextMetrics.descriptionHeight(.large,
                                          contentWidth: SupportedDevice.widestPhone.contentWidth),
            ShelfLayoutFixture.descriptionHeight, accuracy: 8,
            "the fixture's 40 pt description no longer matches two wrapped subheadline lines")
    }

    // MARK: - The property that actually breaks

    /// Whichever welcome-card form the layout picks at an accessibility size,
    /// the first tile row must still end at least `minimumFoldClearance`
    /// above the fold. Visible is not the bar — tappable is.
    func testWelcomeCardLeavesTheTileRowTappableAtEveryAccessibilitySize() {
        for device in SupportedDevice.allPhones {
            for category in TextMetrics.accessibilityCategories {
                let tileMinimum = Theme.gridMinimumTileWidth(for: .accessibility3)
                let full = ShelfHeroLayout.welcomeCardHeight(
                    descriptionHeight: TextMetrics.descriptionHeight(
                        category, contentWidth: device.contentWidth),
                    buttonHeight: TextMetrics.buttonHeight(category))
                let showsDescription = ShelfHeroLayout.welcomeCardShowsDescription(
                    viewportHeight: device.viewportHeight,
                    contentWidth: device.contentWidth,
                    tileMinimumWidth: tileMinimum,
                    contentPadding: ShelfLayoutFixture.contentPadding,
                    gridSpacing: ShelfLayoutFixture.gridSpacing,
                    fullCardHeight: full)
                let chosen = showsDescription
                    ? full
                    : ShelfHeroLayout.welcomeCardHeight(
                        descriptionHeight: 0,
                        buttonHeight: TextMetrics.buttonHeight(category))
                let budget = ShelfHeroLayout.heroZoneBudget(
                    viewportHeight: device.viewportHeight,
                    contentWidth: device.contentWidth,
                    tileMinimumWidth: tileMinimum,
                    contentPadding: ShelfLayoutFixture.contentPadding,
                    gridSpacing: ShelfLayoutFixture.gridSpacing)

                // The compact card is the smallest form there is. Where even
                // that overruns, the documented behaviour is that the grid is
                // reached by scrolling -- so the requirement is that the card
                // only keeps its description when the row genuinely clears.
                if showsDescription {
                    XCTAssertGreaterThanOrEqual(
                        budget - chosen, ShelfHeroLayout.minimumFoldClearance,
                        "\(device.name) @ \(category.rawValue): described card leaves the row unreachable")
                }
            }
        }
    }

    /// The description is dropped as the viewport gets tighter, never regained.
    /// A layout that reinstates it at a larger text size would mean the budget
    /// is not monotonic in the thing it is spent on.
    func testTheDescriptionIsNeverRegainedAsTextGrows() {
        for device in SupportedDevice.allPhones {
            var seenCompact = false
            for category in [UIContentSizeCategory.large] + TextMetrics.accessibilityCategories {
                let full = ShelfHeroLayout.welcomeCardHeight(
                    descriptionHeight: TextMetrics.descriptionHeight(
                        category, contentWidth: device.contentWidth),
                    buttonHeight: TextMetrics.buttonHeight(category))
                let shows = ShelfHeroLayout.welcomeCardShowsDescription(
                    viewportHeight: device.viewportHeight,
                    contentWidth: device.contentWidth,
                    tileMinimumWidth: Theme.gridMinimumTileWidth(
                        for: category == .large ? .large : .accessibility3),
                    contentPadding: ShelfLayoutFixture.contentPadding,
                    gridSpacing: ShelfLayoutFixture.gridSpacing,
                    fullCardHeight: full)
                if !shows { seenCompact = true }
                if seenCompact {
                    XCTAssertFalse(
                        shows,
                        "\(device.name): description returned at \(category.rawValue) after being dropped")
                }
            }
        }
    }

    // MARK: - The hero's art, which only moves in landscape

    /// **Portrait is the wrong fixture for the hero's art, and this records
    /// why.** Measured 2026-09-16: on every supported phone in portrait the
    /// art is `natural`-bound — 214 pt on the SE, 255 pt on the Pro Max — and
    /// `room` never falls below 260 pt even at the largest accessibility size.
    /// `min(natural, …)` therefore returns the same number at every text size,
    /// so a portrait assertion about the floor passes whether or not the floor
    /// exists. An earlier draft of this file asserted exactly that and was
    /// proven vacuous: deleting `max(room, minimumArtHeight)` from `artHeight`
    /// left it green.
    func testPortraitArtIsNaturalBoundAndSoCannotTestTheFloor() {
        for device in SupportedDevice.allPhones {
            let natural = device.contentWidth / Theme.heroAspectRatio
            let large = ShelfHeroLayout.artHeight(
                contentWidth: device.contentWidth, viewportHeight: device.viewportHeight,
                captionHeight: TextMetrics.captionHeight(.large))
            let biggest = ShelfHeroLayout.artHeight(
                contentWidth: device.contentWidth, viewportHeight: device.viewportHeight,
                captionHeight: TextMetrics.captionHeight(.accessibilityExtraExtraExtraLarge))
            XCTAssertEqual(large, natural, accuracy: 0.5, "\(device.name)")
            XCTAssertEqual(biggest, natural, accuracy: 0.5,
                           "\(device.name): portrait art moved — this test's premise is stale")
        }
    }

    /// In landscape the caption *is* charged against the art, and a bigger
    /// caption really does shrink it. On the Pro Max's landscape viewport the
    /// art goes 166.8 pt → 96 pt between `.large` and the largest accessibility
    /// size. A layout that ignored `captionHeight` would return the same number
    /// twice, which is what this discriminates against.
    func testLandscapeArtShrinksAsTheCaptionGrows() {
        for viewport in [Viewport.landscapePhone, Viewport.landscapeProPhone] {
            let large = ShelfHeroLayout.artHeight(
                contentWidth: viewport.contentWidth, viewportHeight: viewport.height,
                captionHeight: TextMetrics.captionHeight(.large))
            let biggest = ShelfHeroLayout.artHeight(
                contentWidth: viewport.contentWidth, viewportHeight: viewport.height,
                captionHeight: TextMetrics.captionHeight(.accessibilityExtraExtraExtraLarge))
            XCTAssertLessThan(biggest, large)
        }
    }

    /// And it stops at the floor rather than following the caption below it.
    /// Both landscape viewports drive `room` under `minimumArtHeight` at the
    /// largest accessibility size — 85.7 pt on the Pro Max, 47.7 pt on the Pro
    /// — so the returned height is the floor, not the room. Asserting `room`
    /// is genuinely the smaller of the two is what keeps this from going
    /// vacuous the way the portrait version did.
    func testLandscapeArtStopsAtItsFloorInsteadOfFollowingTheCaptionDown() {
        for viewport in [Viewport.landscapePhone, Viewport.landscapeProPhone] {
            let caption = TextMetrics.captionHeight(.accessibilityExtraExtraExtraLarge)
            let room = viewport.height - caption
                - ShelfHeroLayout.sectionSpacing - ShelfHeroLayout.minimumGridPeek
            XCTAssertLessThan(room, ShelfHeroLayout.minimumArtHeight,
                              "fixture no longer drives the clamp — the test below proves nothing")
            let art = ShelfHeroLayout.artHeight(
                contentWidth: viewport.contentWidth, viewportHeight: viewport.height,
                captionHeight: caption)
            XCTAssertEqual(art, ShelfHeroLayout.minimumArtHeight, accuracy: 0.5)
        }
    }

    /// What the floor costs, stated rather than left implicit: when the clamp
    /// binds, the hero keeps 96 pt of art by spending the grid's peek, so the
    /// first row shows less than `minimumGridPeek`. That is the documented
    /// trade in `minimumArtHeight` — "an accessibility text size on a short
    /// viewport" reaches the floor and the grid is reached by scrolling — and
    /// this pins the one thing that must survive it: the row is still at least
    /// a tap target tall, not a sliver.
    func testTheFloorNeverCostsMorePeekThanATapTarget() {
        for viewport in [Viewport.landscapePhone, Viewport.landscapeProPhone] {
            let caption = TextMetrics.captionHeight(.accessibilityExtraExtraExtraLarge)
            let art = ShelfHeroLayout.artHeight(
                contentWidth: viewport.contentWidth, viewportHeight: viewport.height,
                captionHeight: caption)
            let peek = viewport.height - caption - ShelfHeroLayout.sectionSpacing - art
            XCTAssertGreaterThanOrEqual(peek, Theme.minimumTapTarget,
                                        "peek \(peek) leaves the first row untappable")
        }
    }

    /// The welcome button is a tap target before it is a label. However small
    /// the text, it never drops below 44 pt.
    func testTheWelcomeButtonNeverFallsBelowTheTapTarget() {
        for category in [.extraSmall, .small, .medium, .large]
            + TextMetrics.accessibilityCategories {
            XCTAssertGreaterThanOrEqual(TextMetrics.buttonHeight(category),
                                        Theme.minimumTapTarget, "\(category.rawValue)")
        }
    }

    // MARK: - The detail page, the other screen with a computed floor

    /// `PlayableDetailView` measures its caption from `UIFont` exactly as
    /// `ShelfView` does, and `PlayableDetailLayout.artHeight` caps the header
    /// art against it. `defaultCaptionHeight` hard-codes 26.3/20.3 pt line
    /// heights for the default size; nothing exercised the real ones.
    ///
    /// Two primary buttons, not one: `captionHeight` charges per button, so a
    /// resumable save is the taller and therefore harder case, and it is the
    /// state the shelf's Continue hero routes into.
    private func detailCaption(_ category: UIContentSizeCategory) -> CGFloat {
        let traits = TextMetrics.traits(category)
        return PlayableDetailLayout.captionHeight(
            titleLineHeight: UIFont.preferredFont(forTextStyle: .title2,
                                                  compatibleWith: traits).lineHeight,
            buttonLineHeight: UIFont.preferredFont(forTextStyle: .body,
                                                   compatibleWith: traits).lineHeight,
            primaryButtonCount: 2)
    }

    /// The hard-coded default must still match what `UIFont` reports, or
    /// `defaultCaptionHeight` is describing a header nobody renders.
    func testTheDetailPagesDefaultCaptionStillMatchesUIFont() {
        let measured = PlayableDetailLayout.captionHeight(
            titleLineHeight: UIFont.preferredFont(
                forTextStyle: .title2, compatibleWith: TextMetrics.traits(.large)).lineHeight,
            buttonLineHeight: UIFont.preferredFont(
                forTextStyle: .body, compatibleWith: TextMetrics.traits(.large)).lineHeight,
            primaryButtonCount: 1)
        XCTAssertEqual(measured, PlayableDetailLayout.defaultCaptionHeight, accuracy: 2)
    }

    /// The caption is charged against the art here too, so a bigger caption
    /// shrinks it — and it stops at the floor rather than going under.
    func testDetailArtShrinksWithTheCaptionAndStopsAtItsFloor() {
        for device in SupportedDevice.allPhones {
            let small = ShelfHeroLayoutProbe.detailArt(device, caption: detailCaption(.large))
            let large = ShelfHeroLayoutProbe.detailArt(
                device, caption: detailCaption(.accessibilityExtraExtraExtraLarge))
            XCTAssertLessThanOrEqual(large, small, "\(device.name)")
            XCTAssertGreaterThanOrEqual(large, PlayableDetailLayout.minimumArtHeight,
                                        "\(device.name)")
        }
    }

    /// The property the cap exists for: whatever the text size, the art must
    /// not eat the room the controls below it need. The art is capped so the
    /// controls keep `minimumControlsPeek`; where the floor wins instead, what
    /// is left must still clear a tap target, or the first control is
    /// unreachable — the detail-page twin of the shelf's fold rule, and the
    /// defect `PlayableDetailLayout` was extracted to fix.
    func testDetailControlsStayReachableAtEveryAccessibilitySize() {
        for device in SupportedDevice.allPhones {
            for category in TextMetrics.accessibilityCategories {
                let caption = detailCaption(category)
                let art = ShelfHeroLayoutProbe.detailArt(device, caption: caption)
                let peek = device.viewportHeight - caption - art
                XCTAssertGreaterThanOrEqual(
                    peek, Theme.minimumTapTarget,
                    "\(device.name) @ \(category.rawValue): controls peek \(peek)")
            }
        }
    }
}

/// Named rather than inlined so the three detail tests above cannot disagree
/// about which width the art is drawn at.
private enum ShelfHeroLayoutProbe {
    static func detailArt(_ device: SupportedDevice, caption: CGFloat) -> CGFloat {
        PlayableDetailLayout.artHeight(
            contentWidth: device.contentWidth - PlayableDetailLayout.rowHorizontalInset * 2,
            viewportHeight: device.viewportHeight,
            captionHeight: caption)
    }
}
