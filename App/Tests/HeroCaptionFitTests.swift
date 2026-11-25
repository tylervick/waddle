import SwiftUI
import UIKit
import XCTest
@testable import Waddle

/// Issue #457: on a closed iPhone Duo held on its side, at the largest
/// accessibility size, the Continue hero's button ended 23 pt below the
/// viewport, under the home indicator.
///
/// The hero there is side by side, and the caption beside the art (title,
/// "Last played …", then the buttons) is text at the reader's size and taller
/// than the 350 pt viewport. The fix drops the last-played line wherever, and
/// only where, Continue would otherwise end below the viewport
/// (`ShelfHeroLayout.sideBySideCaptionShowsLastPlayed`).
///
/// That rule is fed heights worked out from `UIFont`, never a frame of the
/// hero's own (issue #437). So every case here takes Continue's bottom from
/// the caption as SwiftUI really lays it out, `HeroSideBySideCaption` hosted
/// at the caption's width, and checks the arithmetic against it as well.
/// What the screen shows was looked at on the simulator; the captures are in
/// the pull request (`docs/learnings/geometry-tests-cannot-see-the-screen.md`).
@MainActor
final class HeroCaptionFitTests: XCTestCase {

    private static let padding: CGFloat = 16

    /// The closed Duo on its side, as `ShelfTileLargeTextTests` measured it:
    /// a 678x466 window, 562 pt of content, a 350 pt viewport.
    private static let duoClosedLandscape = Viewport(contentWidth: 562, height: 350)
    /// The open Duo, wide: side by side at every size, and roomy.
    private static let duoOpen = Viewport(contentWidth: 835, height: 555)

    private static let title = "Freedoom Phase 1"
    /// Issue #493's long titles, 43 and 44 characters. Imported WADs and
    /// presets are named by their files or by the user, so titles this long
    /// are realistic. Each wraps to four lines or more at the accessibility
    /// sizes, and alone pushed Continue below the closed landscape viewport.
    private static let longTitles = ["Sunlust + Eviternity + Going Down + Ancient",
                                     "Doom 2 the Way id Did: Lost Episodes Remixed"]
    private static let titles = [title] + longTitles
    /// The issue's own line: two wide digits, the longest the line gets in
    /// minutes.
    private static let lastPlayed = "Last played 23 minutes ago"

    private func category(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        UIContentSizeCategory(size)
    }

    private func hostedSize(_ view: some View, width: CGFloat?, _ size: DynamicTypeSize) -> CGSize {
        let host = UIHostingController(rootView: AnyView(view.environment(\.dynamicTypeSize, size)))
        return host.sizeThatFits(in: CGSize(width: width ?? .greatestFiniteMagnitude,
                                            height: .greatestFiniteMagnitude))
    }

    /// What `ShelfView.heroButtonLabelGauge` reads: the wider and the taller
    /// label, measured from the labels themselves.
    private func labelGauge(_ size: DynamicTypeSize) -> CGSize {
        let labels = ZStack {
            HeroSideBySideCaption.continueLabel
            HeroSideBySideCaption.newGameLabel
        }
        .font(Theme.Typography.button)
        .fixedSize()
        let measured = hostedSize(labels, width: nil, size)
        return CGSize(width: ceil(measured.width), height: ceil(measured.height))
    }

    private func buttonMinimumWidth(_ size: DynamicTypeSize) -> CGFloat {
        labelGauge(size).width + Theme.Spacing.base * 2
    }

    private func buttonHeight(_ size: DynamicTypeSize) -> CGFloat {
        HeroSideBySideCaption.buttonHeight(labelHeight: labelGauge(size).height)
    }

    private struct Caption {
        let width: CGFloat
        let arrangement: ShelfHeroLayout.ButtonArrangement
    }

    /// The caption's width and button arrangement in `viewport`, the way
    /// `ShelfView.sideBySideHeroCaption` works them out.
    private func caption(_ viewport: Viewport, _ size: DynamicTypeSize) -> Caption {
        let minimum = buttonMinimumWidth(size)
        let width = ShelfHeroLayout.sideBySideCaptionWidth(contentWidth: viewport.contentWidth,
                                                           viewportHeight: viewport.height,
                                                           captionMinimumWidth: minimum)
        return Caption(width: width,
                       arrangement: ShelfHeroLayout.buttonArrangement(captionWidth: width,
                                                                      buttonMinimumWidth: minimum))
    }

    /// The rule's answer in `viewport`, from the same arithmetic `ShelfView`
    /// hands it.
    private func showsLastPlayed(_ viewport: Viewport, _ size: DynamicTypeSize,
                                 title: String = HeroCaptionFitTests.title) -> Bool {
        let width = caption(viewport, size).width
        return ShelfHeroLayout.sideBySideCaptionShowsLastPlayed(
            viewportHeight: viewport.height,
            contentPadding: Self.padding,
            titleHeight: HeroSideBySideCaption.titleHeight(title, width: width, category: category(size)),
            lastPlayedHeight: HeroSideBySideCaption.lastPlayedHeight(Self.lastPlayed, width: width,
                                                                     category: category(size)),
            buttonHeight: buttonHeight(size))
    }

    /// The title's line cap in `viewport`, the way `ShelfView` works it out:
    /// none while the line is kept, else the rule's answer (issue #493).
    private func titleLineLimit(_ viewport: Viewport, _ size: DynamicTypeSize,
                                title: String = HeroCaptionFitTests.title) -> Int? {
        guard !showsLastPlayed(viewport, size, title: title) else { return nil }
        let width = caption(viewport, size).width
        return ShelfHeroLayout.sideBySideTitleLineLimit(
            viewportHeight: viewport.height,
            contentPadding: Self.padding,
            titleHeight: HeroSideBySideCaption.titleHeight(title, width: width, category: category(size)),
            titleLineHeight: HeroSideBySideCaption.titleLineHeight(category: category(size)),
            buttonHeight: buttonHeight(size))
    }

    /// The title alone as SwiftUI draws it at the caption's width.
    private func drawnTitleHeight(_ viewport: Viewport, _ size: DynamicTypeSize,
                                  title: String, lineLimit: Int?) -> CGFloat {
        let text = Text(title).font(Theme.Typography.heroTitle).lineLimit(lineLimit)
        return hostedSize(text, width: caption(viewport, size).width, size).height
    }

    /// Where Continue ends, from the caption's top, as SwiftUI draws it.
    /// Continue is the first button; in a column, New Game and the gap above
    /// it are what is under it, and a button is the same height alone.
    private func drawnContinueBottom(_ viewport: Viewport, _ size: DynamicTypeSize,
                                     lastPlayed: Bool, title: String = HeroCaptionFitTests.title,
                                     titleLineLimit: Int? = nil) -> CGFloat {
        let caption = caption(viewport, size)
        let view = HeroSideBySideCaption(title: title,
                                         titleLineLimit: titleLineLimit,
                                         lastPlayed: lastPlayed ? Self.lastPlayed : nil,
                                         buttonArrangement: caption.arrangement)
        let whole = hostedSize(view, width: caption.width, size).height
        guard caption.arrangement == .column else { return whole }
        let button = hostedSize(Button {} label: { HeroSideBySideCaption.newGameLabel }
                                    .buttonStyle(.waddleSecondary),
                                width: caption.width, size).height
        return whole - Theme.Spacing.sm - button
    }

    /// Where Continue ends by the arithmetic the rule is fed.
    /// A capped title counts as its cap's lines, as `ShelfHeroLayout` does.
    private func computedContinueBottom(_ viewport: Viewport, _ size: DynamicTypeSize,
                                        lastPlayed: Bool, title: String = HeroCaptionFitTests.title,
                                        titleLineLimit: Int? = nil) -> CGFloat {
        let width = caption(viewport, size).width
        let wrapped = HeroSideBySideCaption.titleHeight(title, width: width, category: category(size))
        let titleHeight = titleLineLimit.map {
            min(wrapped, ShelfHeroLayout.cappedTitleHeight(
                lines: $0, lineHeight: HeroSideBySideCaption.titleLineHeight(category: category(size))))
        } ?? wrapped
        return ShelfHeroLayout.sideBySideContinueBottom(
            titleHeight: titleHeight,
            lastPlayedHeight: lastPlayed
                ? HeroSideBySideCaption.lastPlayedHeight(Self.lastPlayed, width: width, category: category(size))
                : 0,
            buttonHeight: buttonHeight(size))
    }

    // MARK: The defect

    /// What `main` drew: with the line kept, at the largest accessibility
    /// size, Continue ends below the closed landscape viewport.
    func testWithItsLastPlayedLineContinueEndsBelowTheClosedLandscapeViewport() {
        let bottom = Self.padding + drawnContinueBottom(Self.duoClosedLandscape, .accessibility5, lastPlayed: true)
        XCTAssertGreaterThan(bottom, Self.duoClosedLandscape.height,
                             "the case no longer reproduces issue #457")
    }

    // MARK: The fix

    /// At every Dynamic Type size, with the shelf at its top, the whole
    /// Continue button is inside the closed landscape viewport.
    /// For any title: issue #493's long ones too, whose title is capped
    /// where dropping the line is not enough.
    func testContinueEndsInsideTheClosedLandscapeViewportAtEverySize() {
        let viewport = Self.duoClosedLandscape
        for title in Self.titles {
            for size in DynamicTypeSize.allCases {
                let shows = showsLastPlayed(viewport, size, title: title)
                let limit = titleLineLimit(viewport, size, title: title)
                let bottom = Self.padding + drawnContinueBottom(viewport, size, lastPlayed: shows,
                                                                title: title, titleLineLimit: limit)
                XCTAssertLessThanOrEqual(bottom, viewport.height,
                                         "\(title) at \(size): Continue ends at \(bottom), the line "
                                         + "\(shows ? "kept" : "dropped"), title cap \(limit.map(String.init) ?? "none")")
            }
        }
    }

    /// The rule's heights are the caption's: at every size, both with and
    /// without the line, the arithmetic never puts Continue's bottom above
    /// where SwiftUI draws it (which would keep a line that does not fit),
    /// and is at most five points below it. `UIFont`'s wrapped text is a
    /// point or two taller than SwiftUI's at the standard sizes; the button
    /// is measured from its label because `UIFont` came out short of it.
    func testTheArithmeticNeverUnderstatesTheDrawnCaption() {
        for viewport in [Self.duoClosedLandscape, Self.duoOpen] {
            for size in DynamicTypeSize.allCases {
                for line in [true, false] {
                    let drawn = drawnContinueBottom(viewport, size, lastPlayed: line)
                    let computed = computedContinueBottom(viewport, size, lastPlayed: line)
                    let context = "\(size) in \(viewport.contentWidth), line \(line)"
                    XCTAssertGreaterThanOrEqual(computed, drawn - 0.01, context)
                    XCTAssertLessThanOrEqual(computed, drawn + 5, context)
                }
                // A capped title (issue #493): the long titles, without the
                // line, at the cap the rule gives them here.
                for title in Self.longTitles {
                    guard let limit = titleLineLimit(viewport, size, title: title) else { continue }
                    let drawn = drawnContinueBottom(viewport, size, lastPlayed: false,
                                                    title: title, titleLineLimit: limit)
                    let computed = computedContinueBottom(viewport, size, lastPlayed: false,
                                                          title: title, titleLineLimit: limit)
                    let context = "\(title) capped at \(limit) at \(size) in \(viewport.contentWidth)"
                    XCTAssertGreaterThanOrEqual(computed, drawn - 0.01, context)
                    XCTAssertLessThanOrEqual(computed, drawn + 5, context)
                }
            }
        }
    }

    /// The default size and the largest standard one keep their line in the
    /// closed landscape window, so they are drawn as before.
    func testTheStandardSizesKeepTheirLine() {
        for size in DynamicTypeSize.allCases where !size.isAccessibilitySize {
            XCTAssertTrue(showsLastPlayed(Self.duoClosedLandscape, size), "\(size)")
        }
    }

    /// The largest accessibility size drops it there.
    func testTheLargestSizeDropsItsLineInClosedLandscape() {
        XCTAssertFalse(showsLastPlayed(Self.duoClosedLandscape, .accessibility5))
    }

    /// The open Duo has room at every size, so nothing there changes.
    func testTheOpenDuoKeepsItsLineAtEverySize() {
        for size in DynamicTypeSize.allCases {
            XCTAssertTrue(showsLastPlayed(Self.duoOpen, size), "\(size)")
        }
    }

    // MARK: The title gives way next (issue #493)

    /// What `main` drew for a long title: with the line already dropped and
    /// the title uncapped, Continue ends below the closed landscape viewport
    /// at `accessibility3` to `accessibility5`.
    func testUncappedALongTitlePushesContinueBelowTheClosedLandscapeViewport() {
        let viewport = Self.duoClosedLandscape
        let bottom = Self.padding + drawnContinueBottom(viewport, .accessibility3, lastPlayed: false,
                                                        title: Self.longTitles[1])
        XCTAssertGreaterThan(bottom, viewport.height, "the case no longer reproduces issue #493")
    }

    /// The cap is lifted wherever Continue fits without it: "Freedoom Phase 1"
    /// at every size, every title at the standard sizes, and every title on
    /// the open Duo are drawn exactly as before.
    func testTheTitleIsUncappedWhereverContinueFitsWithoutACap() {
        for size in DynamicTypeSize.allCases {
            XCTAssertNil(titleLineLimit(Self.duoClosedLandscape, size), "\(Self.title) at \(size)")
            for title in Self.titles {
                XCTAssertNil(titleLineLimit(Self.duoOpen, size, title: title), "\(title) open at \(size)")
                if !size.isAccessibilitySize {
                    XCTAssertNil(titleLineLimit(Self.duoClosedLandscape, size, title: title),
                                 "\(title) at \(size)")
                }
            }
        }
    }

    /// Where it is capped, the title is capped only after the line is gone,
    /// only where the uncapped caption would end below the viewport, and
    /// still draws at least one line.
    func testACappedTitleIsCappedOnlyWhereItMustAndKeepsALine() {
        let viewport = Self.duoClosedLandscape
        let oneLine = drawnTitleHeight(viewport, .large, title: "Doom", lineLimit: nil)
        for title in Self.titles {
            for size in DynamicTypeSize.allCases {
                let limit = titleLineLimit(viewport, size, title: title)
                let uncapped = Self.padding + computedContinueBottom(viewport, size, lastPlayed: false, title: title)
                let context = "\(title) at \(size)"
                guard let limit else {
                    if !showsLastPlayed(viewport, size, title: title) {
                        XCTAssertLessThanOrEqual(uncapped, viewport.height, context)
                    }
                    continue
                }
                XCTAssertFalse(showsLastPlayed(viewport, size, title: title), context)
                XCTAssertGreaterThan(uncapped, viewport.height, context)
                XCTAssertGreaterThanOrEqual(limit, 1, context)
                XCTAssertGreaterThanOrEqual(drawnTitleHeight(viewport, size, title: title, lineLimit: limit),
                                            oneLine, context)
            }
        }
    }

    /// The long titles are capped at `accessibility3` to `accessibility5`,
    /// where the issue measured Continue below the viewport.
    func testTheLongTitlesAreCappedAtTheLargestSizes() {
        for size in [DynamicTypeSize.accessibility3, .accessibility4, .accessibility5] {
            XCTAssertNotNil(titleLineLimit(Self.duoClosedLandscape, size, title: Self.longTitles[1]), "\(size)")
        }
        XCTAssertNotNil(titleLineLimit(Self.duoClosedLandscape, .accessibility5, title: Self.longTitles[0]))
    }

    // MARK: The rule on its own

    func testAnUnmeasuredViewportLeavesTheTitleUncapped() {
        XCTAssertNil(ShelfHeroLayout.sideBySideTitleLineLimit(
            viewportHeight: 0, contentPadding: 16, titleHeight: 500, titleLineHeight: 30, buttonHeight: 44))
    }

    func testTheTitleCapLeavesContinueOnTheViewportAndNeverGoesBelowOneLine() {
        // Below the title: 6 + 8 + 44 = 58, so 220 - 16 - 58 = 146 pt of title.
        XCTAssertNil(ShelfHeroLayout.sideBySideTitleLineLimit(
            viewportHeight: 220, contentPadding: 16, titleHeight: 146, titleLineHeight: 30, buttonHeight: 44))
        XCTAssertEqual(ShelfHeroLayout.sideBySideTitleLineLimit(
            viewportHeight: 220, contentPadding: 16, titleHeight: 180, titleLineHeight: 30, buttonHeight: 44), 4)
        // 146 / 29 is 5.03 lines, and 5 lines are 145 pt.
        XCTAssertEqual(ShelfHeroLayout.sideBySideTitleLineLimit(
            viewportHeight: 220, contentPadding: 16, titleHeight: 180, titleLineHeight: 29, buttonHeight: 44), 5)
        // 145.5 / 29.05 is 5.008 lines, but 5 lines round up to 146 pt,
        // past the room, so 4.
        XCTAssertEqual(ShelfHeroLayout.sideBySideTitleLineLimit(
            viewportHeight: 220, contentPadding: 16.5, titleHeight: 180, titleLineHeight: 29.05,
            buttonHeight: 44), 4)
        // No room at all still keeps one line.
        XCTAssertEqual(ShelfHeroLayout.sideBySideTitleLineLimit(
            viewportHeight: 60, contentPadding: 16, titleHeight: 180, titleLineHeight: 30, buttonHeight: 44), 1)
    }

    func testAnUnmeasuredViewportKeepsTheLine() {
        XCTAssertTrue(ShelfHeroLayout.sideBySideCaptionShowsLastPlayed(
            viewportHeight: 0, contentPadding: 16, titleHeight: 500, lastPlayedHeight: 500, buttonHeight: 500))
    }

    func testTheLineIsKeptWhenContinueEndsExactlyOnTheViewport() {
        // 16 + 100 + (40 + 6) + 6 + 8 + 44 = 220
        XCTAssertTrue(ShelfHeroLayout.sideBySideCaptionShowsLastPlayed(
            viewportHeight: 220, contentPadding: 16, titleHeight: 100, lastPlayedHeight: 40, buttonHeight: 44))
        XCTAssertFalse(ShelfHeroLayout.sideBySideCaptionShowsLastPlayed(
            viewportHeight: 219.5, contentPadding: 16, titleHeight: 100, lastPlayedHeight: 40, buttonHeight: 44))
    }
}
