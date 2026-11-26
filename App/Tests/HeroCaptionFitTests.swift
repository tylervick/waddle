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
    /// An iPhone 11 on its side (414x896 pt at 2x, the XR's screen), measured
    /// from the shelf's own scroll view on the iOS 27.0 simulator on
    /// 2026-11-25 at accessibility5: 768 pt of content, a 316 pt viewport.
    /// The review of pull request 546 estimated it at 740x316 and found a
    /// three-line title whose Continue ends exactly on the viewport there.
    private static let iPhone11Landscape = Viewport(contentWidth: 768, height: 316)
    /// Every window the hero is checked in.
    private static let viewports = [duoClosedLandscape, duoOpen, iPhone11Landscape,
                                    .landscapePhone, .landscapeProPhone]
    /// A landscape iPhone 12 mini and 11 Pro, as the review of pull request
    /// 553 estimated them from the chrome measured on the iPhone 11 and 17
    /// Pro, not measured themselves. At AX5 New Game does not fit under even
    /// a one-line title there.
    private static let iPhone12MiniLandscape = Viewport(contentWidth: 762, height: 262)
    private static let iPhone11ProLandscape = Viewport(contentWidth: 762, height: 277)
    /// Windows where the review of pull request 553 found the rules giving
    /// way for nothing: New Game out of reach on the two phones above, and
    /// the line dropped though the caption with it fitted by 0.67 to 3 pt
    /// in the other four, at AX4 and at medium or xLarge.
    private static let reviewWindows = [iPhone12MiniLandscape, iPhone11ProLandscape,
                                        Viewport(contentWidth: 840, height: 316),
                                        Viewport(contentWidth: 900, height: 316),
                                        Viewport(contentWidth: 480, height: 280),
                                        Viewport(contentWidth: 540, height: 280)]

    private static let title = "Freedoom Phase 1"
    /// Issue #493's long titles, 43 and 44 characters. Imported WADs and
    /// presets are named by their files or by the user, so titles this long
    /// are realistic. Each wraps to four lines or more at the accessibility
    /// sizes, and alone pushed Continue below the closed landscape viewport.
    private static let longTitles = ["Sunlust + Eviternity + Going Down + Ancient",
                                     "Doom 2 the Way id Did: Lost Episodes Remixed"]
    /// Titles in the scripts the review of pull request 546 swept. SwiftUI
    /// gives every script the same line, but TextKit gives a line the
    /// height of its tallest fallback font, so these are what keep the
    /// arithmetic honest outside Latin.
    private static let scriptTitles = [
        "WWWWWWWW MMMMMMMM WWWWWWWW MMMMMMMM WWWW",
        "Ångström Ågård ÅÅÅÅ Ölgård Øresund Remix",
        "Đôi Mắt Ở Địa Ngục Ỷ Lại Bản Làm Lại Đầy Đủ",
        "دوم ٢ بطريقة آي دي: الحلقات المفقودة المعاد مزجها",
        "डूम दो: खोए हुए एपिसोड का पूरा संस्करण",
        "ดูมสอง วิถีแห่งไอดี ตอนที่สูญหาย ฉบับรีมิกซ์",
        "ドゥーム2 アイディーのやり方 失われたエピソード リミックス",
        "毁灭战士二 失落章节 重制混音 完整版本 典藏",
        "😀 Doom 🎮 Eternal 🔥 Phase 💀 Remix 🎯 Edition",
        "SunlustEviternityGoingDownAncientAliensRemix",
        "Freedoom Phase 2 + SCYTHE",
        "ดูมสอง วิถีแห่งไอดี",
        "डूम दो: खोए हुए एपिसोड",
        "毁灭战士二 失落章节 重制",
        // Korean, which SwiftUI breaks between words and TextKit 1 broke
        // between syllables (review of pull request 546).
        "둠 이터널 파티 리믹스 에디션 디럭스",
        "프리둠 페이즈 투 사이드 리믹스 에디션",
        "프리둠 페이즈 투 시사이드 리믹스 에디션 완전판 특별 모음집",
        "둠 2 아이디의 방식 잃어버린 에피소드 리믹스",
        // Soft hyphens, which TextKit 1 broke at and SwiftUI does not, and
        // a word too long for the line, which both break by character.
        "Doom\u{00AD}Wad\u{00AD}Pack\u{00AD}Ultra\u{00AD}Deluxe\u{00AD}Edition",
        "Supercalifragilisticexpialidocious",
    ]
    private static let titles = [title] + longTitles + scriptTitles
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
    /// label, measured from the labels themselves, both rounded up to the
    /// point, which is what the last-played rule takes.
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

    /// One button from the label's height as drawn, unrounded: what the
    /// title's cap takes. Rounded up, it was up to two thirds of a point
    /// over the drawn button, and capped titles that ended Continue exactly
    /// on the viewport.
    private func exactButtonHeight(_ size: DynamicTypeSize) -> CGFloat {
        let labels = ZStack {
            HeroSideBySideCaption.continueLabel
            HeroSideBySideCaption.newGameLabel
        }
        .font(Theme.Typography.button)
        .fixedSize()
        return HeroSideBySideCaption.buttonHeight(labelHeight: hostedSize(labels, width: nil, size).height)
    }

    /// The New Game label alone, as `ShelfView.heroButtonLabelGauge` reads
    /// it: the second button where the two are stacked (issue #547).
    private func newGameLabelHeight(_ size: DynamicTypeSize) -> CGFloat {
        hostedSize(HeroSideBySideCaption.newGameLabel.font(Theme.Typography.button).fixedSize(),
                   width: nil, size).height
    }

    /// New Game's button, rounded the way the last-played rule takes it.
    private func newGameButtonHeight(_ size: DynamicTypeSize) -> CGFloat {
        HeroSideBySideCaption.buttonHeight(labelHeight: ceil(newGameLabelHeight(size)))
    }

    /// New Game's button as drawn, unrounded, the way the title's cap takes it.
    private func exactNewGameButtonHeight(_ size: DynamicTypeSize) -> CGFloat {
        HeroSideBySideCaption.buttonHeight(labelHeight: newGameLabelHeight(size))
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

    /// Whose bottom the rules keep inside `viewport`, the way `ShelfView`
    /// works it out: New Game's where the buttons stack and it can be kept
    /// whole, Continue's otherwise (`sideBySideBoundArrangement`).
    private func boundArrangement(_ viewport: Viewport, _ size: DynamicTypeSize) -> ShelfHeroLayout.ButtonArrangement {
        ShelfHeroLayout.sideBySideBoundArrangement(
            viewportHeight: viewport.height, contentPadding: Self.padding,
            titleFirstLine: titleGauge(size).firstLine,
            buttonHeight: exactButtonHeight(size), newGameButtonHeight: exactNewGameButtonHeight(size),
            buttonArrangement: caption(viewport, size).arrangement)
    }

    /// The rule's answer in `viewport`, from the same arithmetic `ShelfView`
    /// hands it: `main`'s rule for Continue, then, where New Game is the
    /// bound, the same question of New Game from the drawn heights. `bound`
    /// overrides the arrangement; `.row` is what `main` drew.
    private func showsLastPlayed(_ viewport: Viewport, _ size: DynamicTypeSize,
                                 title: String = HeroCaptionFitTests.title,
                                 bound: ShelfHeroLayout.ButtonArrangement? = nil) -> Bool {
        let width = caption(viewport, size).width
        let lastPlayedHeight = HeroSideBySideCaption.lastPlayedHeight(Self.lastPlayed, width: width,
                                                                      category: category(size))
        let continueFits = ShelfHeroLayout.sideBySideCaptionShowsLastPlayed(
            viewportHeight: viewport.height,
            contentPadding: Self.padding,
            titleHeight: HeroSideBySideCaption.titleHeight(title, width: width, category: category(size)),
            lastPlayedHeight: lastPlayedHeight,
            buttonHeight: buttonHeight(size),
            newGameButtonHeight: newGameButtonHeight(size),
            buttonArrangement: .row)
        guard continueFits, (bound ?? boundArrangement(viewport, size)) == .column else { return continueFits }
        let gauge = titleGauge(size)
        return ShelfHeroLayout.sideBySideCaptionShowsLastPlayed(
            viewportHeight: viewport.height,
            contentPadding: Self.padding,
            titleHeight: ShelfHeroLayout.titleHeight(lines: titleLines(viewport, size, title: title),
                                                     firstLine: gauge.firstLine, lineStep: gauge.lineStep),
            lastPlayedHeight: lastPlayedHeight,
            buttonHeight: exactButtonHeight(size),
            newGameButtonHeight: exactNewGameButtonHeight(size),
            buttonArrangement: .column)
    }

    /// The title's line cap in `viewport`, the way `ShelfView` works it out:
    /// none while the line is kept, else the rule's answer (issue #493).
    /// `bound: .row` is what `main` drew.
    private func titleLineLimit(_ viewport: Viewport, _ size: DynamicTypeSize,
                                title: String = HeroCaptionFitTests.title,
                                bound: ShelfHeroLayout.ButtonArrangement? = nil) -> Int? {
        guard !showsLastPlayed(viewport, size, title: title, bound: bound) else { return nil }
        let gauge = titleGauge(size)
        return ShelfHeroLayout.sideBySideTitleLineLimit(
            viewportHeight: viewport.height,
            contentPadding: Self.padding,
            titleLines: titleLines(viewport, size, title: title),
            titleFirstLine: gauge.firstLine,
            titleLineStep: gauge.lineStep,
            buttonHeight: exactButtonHeight(size),
            newGameButtonHeight: exactNewGameButtonHeight(size),
            buttonArrangement: bound ?? boundArrangement(viewport, size))
    }

    /// What `ShelfView.heroTitleLineGauge` reads: one line of the title's
    /// font, and what a second adds, as SwiftUI lays them out.
    private func titleGauge(_ size: DynamicTypeSize) -> (firstLine: CGFloat, lineStep: CGFloat) {
        let one = hostedSize(HeroSideBySideCaption.titleLineGauge(lines: 1), width: nil, size).height
        let two = hostedSize(HeroSideBySideCaption.titleLineGauge(lines: 2), width: nil, size).height
        return (one, two - one)
    }

    private func titleLines(_ viewport: Viewport, _ size: DynamicTypeSize, title: String) -> Int {
        HeroSideBySideCaption.titleLineCount(title, width: caption(viewport, size).width, category: category(size))
    }

    /// The title's height by the arithmetic the cap is worked out with.
    private func computedTitleHeight(_ viewport: Viewport, _ size: DynamicTypeSize,
                                     title: String, lineLimit: Int?) -> CGFloat {
        let gauge = titleGauge(size)
        let lines = titleLines(viewport, size, title: title)
        return ShelfHeroLayout.titleHeight(lines: min(lines, lineLimit ?? lines),
                                           firstLine: gauge.firstLine, lineStep: gauge.lineStep)
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

    /// Where the caption's last button ends, from the caption's top, as
    /// SwiftUI draws it: the whole caption. In a row that is Continue's
    /// bottom too; in a column it is New Game's (issue #547).
    private func drawnButtonsBottom(_ viewport: Viewport, _ size: DynamicTypeSize,
                                    lastPlayed: Bool, title: String = HeroCaptionFitTests.title,
                                    titleLineLimit: Int? = nil) -> CGFloat {
        let caption = caption(viewport, size)
        let view = HeroSideBySideCaption(title: title,
                                         titleLineLimit: titleLineLimit,
                                         lastPlayed: lastPlayed ? Self.lastPlayed : nil,
                                         buttonArrangement: caption.arrangement)
        return hostedSize(view, width: caption.width, size).height
    }

    /// Where Continue ends by the arithmetic the last-played rule is fed.
    private func computedContinueBottom(_ viewport: Viewport, _ size: DynamicTypeSize,
                                        lastPlayed: Bool) -> CGFloat {
        let width = caption(viewport, size).width
        return ShelfHeroLayout.sideBySideContinueBottom(
            titleHeight: HeroSideBySideCaption.titleHeight(Self.title, width: width, category: category(size)),
            lastPlayedHeight: lastPlayed
                ? HeroSideBySideCaption.lastPlayedHeight(Self.lastPlayed, width: width, category: category(size))
                : 0,
            buttonHeight: buttonHeight(size))
    }

    /// Where the buttons end by the same arithmetic: Continue in a row, New
    /// Game under it in a column (issue #547).
    private func computedButtonsBottom(_ viewport: Viewport, _ size: DynamicTypeSize,
                                       lastPlayed: Bool) -> CGFloat {
        let caption = caption(viewport, size)
        return ShelfHeroLayout.sideBySideButtonsBottom(
            titleHeight: HeroSideBySideCaption.titleHeight(Self.title, width: caption.width, category: category(size)),
            lastPlayedHeight: lastPlayed
                ? HeroSideBySideCaption.lastPlayedHeight(Self.lastPlayed, width: caption.width,
                                                         category: category(size))
                : 0,
            buttonHeight: buttonHeight(size),
            newGameButtonHeight: newGameButtonHeight(size),
            buttonArrangement: caption.arrangement)
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
                    // And the buttons' bottom, New Game's where they stack.
                    let drawnButtons = drawnButtonsBottom(viewport, size, lastPlayed: line)
                    let computedButtons = computedButtonsBottom(viewport, size, lastPlayed: line)
                    XCTAssertGreaterThanOrEqual(computedButtons, drawnButtons - 0.01, context + ", buttons")
                    XCTAssertLessThanOrEqual(computedButtons, drawnButtons + 5, context + ", buttons")
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

    /// Continue is whole in every window, for every title in every script,
    /// at every size: the line dropped where it must be, then the title
    /// capped where that is not enough.
    func testContinueEndsInsideEveryViewportForEveryScript() {
        for viewport in Self.viewports {
            for title in Self.titles {
                for size in DynamicTypeSize.allCases {
                    let shows = showsLastPlayed(viewport, size, title: title)
                    let limit = titleLineLimit(viewport, size, title: title)
                    let bottom = Self.padding + drawnContinueBottom(viewport, size, lastPlayed: shows,
                                                                    title: title, titleLineLimit: limit)
                    XCTAssertLessThanOrEqual(bottom, viewport.height,
                                             "\(title) at \(size) in \(viewport.contentWidth)x\(viewport.height): "
                                             + "Continue ends at \(bottom), cap \(limit.map(String.init) ?? "none")")
                }
            }
        }
    }

    /// The cap's arithmetic is the drawing, not an estimate of it: for every
    /// title in every script, at every size, in every window, uncapped and
    /// at every cap short of its lines, the title's height worked out from
    /// its line count and the gauge's first line and step is the height
    /// SwiftUI draws, to the pixel. `UIFont.lineHeight`, rounded as a whole,
    /// was short of it by up to 1.7 pt, and rounded per line was over it by
    /// up to 4 pt at the largest size, where the style's leading is less
    /// than `lineHeight` (review of pull request 546).
    func testTheTitleArithmeticIsWhatSwiftUIDraws() {
        for viewport in Self.viewports {
            for size in DynamicTypeSize.allCases {
                for title in Self.titles {
                    let lines = titleLines(viewport, size, title: title)
                    for cap in [nil] + Array(1..<max(lines, 1)).map(Optional.some) {
                        let drawn = drawnTitleHeight(viewport, size, title: title, lineLimit: cap)
                        let computed = computedTitleHeight(viewport, size, title: title, lineLimit: cap)
                        XCTAssertEqual(computed, drawn, accuracy: 0.01,
                                       "\(title) at \(size) in \(viewport.contentWidth), "
                                       + "\(lines) lines, cap \(cap.map(String.init) ?? "none")")
                    }
                }
            }
        }
    }

    /// Wherever the uncapped caption's buttons are whole (Continue in a row,
    /// New Game too where they stack, issue #547), nothing is capped, so the
    /// hero is drawn exactly as before: every title, every size, every
    /// window. Where a title is capped, the uncapped buttons ended below the
    /// viewport, the line was already gone, and the title keeps at least one
    /// line. Before issue #547 this asked the same of Continue alone.
    func testTheTitleIsCappedOnlyWhereTheUncappedButtonsDidNotFitAndKeepALine() {
        for viewport in Self.viewports {
            let oneLine = titleGauge(.large).firstLine
            for title in Self.titles {
                for size in DynamicTypeSize.allCases {
                    let shows = showsLastPlayed(viewport, size, title: title)
                    let limit = titleLineLimit(viewport, size, title: title)
                    let main = Self.padding + drawnButtonsBottom(viewport, size, lastPlayed: shows, title: title)
                    let context = "\(title) at \(size) in \(viewport.contentWidth)x\(viewport.height), "
                        + "uncapped, the buttons end at \(main)"
                    guard let limit else { continue }
                    XCTAssertFalse(shows, context)
                    XCTAssertGreaterThan(main, viewport.height, context)
                    XCTAssertGreaterThanOrEqual(limit, 1, context)
                    XCTAssertGreaterThanOrEqual(drawnTitleHeight(viewport, size, title: title, lineLimit: limit),
                                                oneLine, context)
                }
                for size in DynamicTypeSize.allCases {
                    let shows = showsLastPlayed(viewport, size, title: title)
                    let main = Self.padding + drawnButtonsBottom(viewport, size, lastPlayed: shows, title: title)
                    if main <= viewport.height {
                        XCTAssertNil(titleLineLimit(viewport, size, title: title),
                                     "\(title) at \(size) in \(viewport.contentWidth)x\(viewport.height): "
                                     + "uncapped, the buttons fitted, ending at \(main)")
                    }
                }
            }
        }
    }

    /// The review's case, in the window measured rather than estimated: an
    /// iPhone 11 on its side at `accessibility5`, where a title wraps to
    /// three lines. The review, working from an estimated 740x316 window,
    /// had `main` end Continue exactly on the viewport there. Measured, it
    /// does not: on the iPhone 11 simulator (2x) `main` ends Continue at
    /// 316.5 pt of a 316 pt viewport, read off a capture, and drawn here it
    /// ends at 316.67 pt. So the title is capped, and Continue then fits.
    ///
    /// The buttons are stacked there, and since issue #547 the cap leaves
    /// New Game whole as well: two lines left it 30 pt below the viewport,
    /// so the title keeps one.
    func testAThreeLineTitleOnTheiPhone11IsCappedBecauseMainEndedPastTheViewport() {
        let viewport = Self.iPhone11Landscape
        let threeLines = Self.titles.filter { titleLines(viewport, .accessibility5, title: $0) == 3 }
        XCTAssertFalse(threeLines.isEmpty, "no title wraps to three lines here any more")
        for title in threeLines {
            XCTAssertFalse(showsLastPlayed(viewport, .accessibility5, title: title), title)
            let main = Self.padding + drawnContinueBottom(viewport, .accessibility5, lastPlayed: false, title: title)
            XCTAssertGreaterThan(main, viewport.height, title)
            let limit = titleLineLimit(viewport, .accessibility5, title: title)
            XCTAssertEqual(limit, 1, title)
            let capped = Self.padding + drawnContinueBottom(viewport, .accessibility5, lastPlayed: false,
                                                            title: title, titleLineLimit: limit)
            XCTAssertLessThanOrEqual(capped, viewport.height, title)
            let buttons = Self.padding + drawnButtonsBottom(viewport, .accessibility5, lastPlayed: false,
                                                            title: title, titleLineLimit: limit)
            XCTAssertLessThanOrEqual(buttons, viewport.height, title)
        }
    }

    /// What the review asked of that case, at the boundary itself: in a
    /// window whose viewport ends exactly where the uncapped caption ends its
    /// buttons, the title is not capped; one pixel shorter, it is. For every
    /// title that wraps, at every accessibility size, in windows as wide as
    /// the iPhone 11's and the closed Duo's. The art's width follows the
    /// viewport's height, so that window is found by drawing the caption
    /// again in it until the buttons' bottom and the viewport agree. Before
    /// issue #547 the boundary was Continue's bottom; where the buttons
    /// stack it is now New Game's.
    func testATitleEndingTheButtonsExactlyOnTheViewportIsNotCapped() {
        let pixel = 1 / UIScreen.main.scale
        var checked = 0
        for width in [Self.iPhone11Landscape.contentWidth, Self.duoClosedLandscape.contentWidth] {
            for size in DynamicTypeSize.allCases where size.isAccessibilitySize {
                for title in Self.titles {
                    var height: CGFloat = 350
                    var exact: Viewport?
                    for _ in 0..<8 {
                        let viewport = Viewport(contentWidth: width, height: height)
                        let main = Self.padding + drawnButtonsBottom(viewport, size, lastPlayed: false, title: title)
                        if abs(main - height) < 0.01 { exact = viewport; break }
                        height = main
                    }
                    guard let exact, titleLines(exact, size, title: title) > 1 else { continue }
                    let short = Viewport(contentWidth: width, height: exact.height - pixel)
                    guard titleLines(short, size, title: title) == titleLines(exact, size, title: title),
                          !showsLastPlayed(exact, size, title: title),
                          !showsLastPlayed(short, size, title: title) else { continue }
                    let context = "\(title) at \(size), \(width) wide, viewport \(exact.height)"
                    XCTAssertNil(titleLineLimit(exact, size, title: title), context)
                    XCTAssertNotNil(titleLineLimit(short, size, title: title), context + " less a pixel")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 20, "too few cases reached the boundary to say anything")
    }

    /// "Freedoom Phase 1" at every size, every title at the standard sizes,
    /// and the issue's titles on the open Duo keep an uncapped title.
    func testTheTitleIsUncappedWhereverContinueFitsWithoutACap() {
        for size in DynamicTypeSize.allCases {
            XCTAssertNil(titleLineLimit(Self.duoClosedLandscape, size), "\(Self.title) at \(size)")
            for title in [Self.title] + Self.longTitles {
                XCTAssertNil(titleLineLimit(Self.duoOpen, size, title: title), "\(title) open at \(size)")
                if !size.isAccessibilitySize {
                    XCTAssertNil(titleLineLimit(Self.duoClosedLandscape, size, title: title),
                                 "\(title) at \(size)")
                }
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

    /// The cap counts the title's lines where SwiftUI breaks them, for every
    /// title, at every size, at widths from a narrow caption to a wide one
    /// in 6 pt steps. The windows above sample only a few caption widths, and
    /// a line count that is wrong at a width they miss is a title capped
    /// where it fitted, or not capped where it did not: TextKit 1 counted
    /// "둠 이터널 파티 리믹스 에디션 디럭스" as two lines at AX5 on a
    /// landscape iPhone 17 Pro where SwiftUI drew three, and Continue ended
    /// 12 pt under the home indicator.
    func testTheLineCountIsSwiftUIsAtEveryWidth() {
        for size in DynamicTypeSize.allCases {
            let gauge = titleGauge(size)
            for title in Self.titles {
                for width in stride(from: CGFloat(120), through: 520, by: 6) {
                    let drawn = hostedSize(Text(title).font(Theme.Typography.heroTitle), width: width, size).height
                    let drawnLines = Int(((drawn - gauge.firstLine) / gauge.lineStep).rounded()) + 1
                    XCTAssertEqual(HeroSideBySideCaption.titleLineCount(title, width: width, category: category(size)),
                                   drawnLines, "\(title) at \(size), \(width) wide")
                }
            }
        }
    }

    /// The review's case on its own: a landscape iPhone 17 Pro at AX5, where
    /// this Korean title draws three lines and ended Continue below the
    /// viewport uncapped. The buttons are stacked there, so since issue #547
    /// the title keeps the one line that leaves New Game whole too.
    func testAKoreanTitleIsCappedOnALandscapeProPhone() {
        let viewport = Viewport.landscapeProPhone
        let title = "둠 이터널 파티 리믹스 에디션 디럭스"
        XCTAssertEqual(titleLines(viewport, .accessibility5, title: title), 3)
        let main = Self.padding + drawnContinueBottom(viewport, .accessibility5, lastPlayed: false, title: title)
        XCTAssertGreaterThan(main, viewport.height, "the case no longer reproduces the review's finding")
        let limit = titleLineLimit(viewport, .accessibility5, title: title)
        XCTAssertEqual(limit, 1)
        let capped = Self.padding + drawnContinueBottom(viewport, .accessibility5, lastPlayed: false,
                                                        title: title, titleLineLimit: limit)
        XCTAssertLessThanOrEqual(capped, viewport.height)
        let buttons = Self.padding + drawnButtonsBottom(viewport, .accessibility5, lastPlayed: false,
                                                        title: title, titleLineLimit: limit)
        XCTAssertLessThanOrEqual(buttons, viewport.height)
    }

    // MARK: New Game is whole too, where the buttons stack (issue #547)

    /// What `main` drew: in the measured iPhone 11 window at the largest
    /// size, the buttons stack, and with Continue whole New Game ended below
    /// the viewport for the issue's title.
    func testOnMainNewGameEndedBelowTheiPhone11Viewport() {
        let viewport = Self.iPhone11Landscape
        let title = Self.longTitles[1]
        XCTAssertEqual(caption(viewport, .accessibility5).arrangement, .column)
        let continueBottom = Self.padding + drawnContinueBottom(viewport, .accessibility5, lastPlayed: false,
                                                                title: title, titleLineLimit: 2)
        let newGameBottom = Self.padding + drawnButtonsBottom(viewport, .accessibility5, lastPlayed: false,
                                                              title: title, titleLineLimit: 2)
        XCTAssertLessThanOrEqual(continueBottom, viewport.height, "Continue was whole on main")
        XCTAssertGreaterThan(newGameBottom, viewport.height, "the case no longer reproduces issue #547")
    }

    /// Both buttons are whole in every window, for every title in every
    /// script, at every size, wherever New Game can be: in a row they end
    /// where Continue does, and in a column New Game ends below it, and the
    /// line and then the title give way for it as they do for Continue.
    /// Where it cannot be, even under a one-line title with no line, the
    /// caption is what `main` drew, and that is checked to be so.
    func testBothButtonsEndInsideEveryViewportWhereNewGameCanFit() {
        for viewport in Self.viewports + Self.reviewWindows {
            for title in Self.titles {
                for size in DynamicTypeSize.allCases {
                    let shows = showsLastPlayed(viewport, size, title: title)
                    let limit = titleLineLimit(viewport, size, title: title)
                    let context = "\(title) at \(size) in \(viewport.contentWidth)x\(viewport.height), "
                        + "\(caption(viewport, size).arrangement), line \(shows ? "kept" : "dropped"), "
                        + "cap \(limit.map(String.init) ?? "none")"
                    let bottom = Self.padding + drawnButtonsBottom(viewport, size, lastPlayed: shows,
                                                                   title: title, titleLineLimit: limit)
                    if caption(viewport, size).arrangement == .row || boundArrangement(viewport, size) == .column {
                        XCTAssertLessThanOrEqual(bottom, viewport.height, context + ": the buttons end at \(bottom)")
                    } else {
                        let leanest = Self.padding + drawnButtonsBottom(viewport, size, lastPlayed: false,
                                                                        title: title, titleLineLimit: 1)
                        XCTAssertGreaterThan(leanest, viewport.height, context + ": New Game would fit at one line")
                        XCTAssertEqual(shows, showsLastPlayed(viewport, size, title: title, bound: .row), context)
                        XCTAssertEqual(limit, titleLineLimit(viewport, size, title: title, bound: .row), context)
                    }
                }
            }
        }
    }

    /// The review's case: on a landscape iPhone 12 mini at AX5, New Game
    /// cannot fit under any title, and the pull request still cut titles
    /// `main` drew on two lines to one, leaving New Game 18 pt below the
    /// viewport anyway. Every title that wraps there keeps what `main`
    /// showed, and Continue stays whole.
    func testWhereNewGameCannotFitTheTitleKeepsWhatMainShowed() {
        let viewport = Self.iPhone12MiniLandscape
        let size = DynamicTypeSize.accessibility5
        XCTAssertEqual(caption(viewport, size).arrangement, .column)
        let leanest = Self.padding + drawnButtonsBottom(viewport, size, lastPlayed: false,
                                                        title: Self.title, titleLineLimit: 1)
        XCTAssertGreaterThan(leanest, viewport.height, "the case no longer reproduces the review's finding")
        XCTAssertEqual(boundArrangement(viewport, size), .row)
        var keptTwoOrMore = 0
        for title in Self.titles where titleLines(viewport, size, title: title) > 1 {
            let main = titleLineLimit(viewport, size, title: title, bound: .row)
            let limit = titleLineLimit(viewport, size, title: title)
            XCTAssertEqual(limit, main, title)
            let lines = min(titleLines(viewport, size, title: title), limit ?? .max)
            if lines >= 2 { keptTwoOrMore += 1 }
            let continueBottom = Self.padding + drawnContinueBottom(viewport, size, lastPlayed: false,
                                                                    title: title, titleLineLimit: limit)
            XCTAssertLessThanOrEqual(continueBottom, viewport.height, title)
        }
        XCTAssertGreaterThan(keptTwoOrMore, 0, "no title keeps two lines here, so nothing is checked")
    }

    /// Nothing gives way where the whole caption fitted: the line is
    /// dropped only where the caption with it ended below the viewport, the
    /// title is capped only where the caption without the line, uncapped,
    /// did, and a capped title is capped at the most lines that fit, so one
    /// more line would not. Wherever `main` drew both buttons whole, this is
    /// what `main` drew.
    func testNothingGivesWayWhereTheWholeCaptionFitted() {
        for viewport in Self.viewports + Self.reviewWindows {
            for title in Self.titles {
                for size in DynamicTypeSize.allCases {
                    let shows = showsLastPlayed(viewport, size, title: title)
                    let limit = titleLineLimit(viewport, size, title: title)
                    let context = "\(title) at \(size) in \(viewport.contentWidth)x\(viewport.height), "
                        + "\(caption(viewport, size).arrangement)"
                    let withLine = Self.padding + drawnButtonsBottom(viewport, size, lastPlayed: true, title: title)
                    if !shows {
                        XCTAssertGreaterThan(withLine, viewport.height, context + ": the line was dropped")
                    }
                    guard let limit else { continue }
                    let uncapped = Self.padding + drawnButtonsBottom(viewport, size, lastPlayed: false, title: title)
                    XCTAssertGreaterThan(uncapped, viewport.height, context + ": capped at \(limit)")
                    // One more line short of the whole title (the whole
                    // title is `uncapped`, just above).
                    if limit + 1 < titleLines(viewport, size, title: title) {
                        let oneMore = Self.padding + drawnButtonsBottom(viewport, size, lastPlayed: false,
                                                                        title: title, titleLineLimit: limit + 1)
                        XCTAssertGreaterThan(oneMore, viewport.height, context + ": \(limit + 1) lines would fit")
                    }
                }
            }
        }
    }

    /// The issue's case, in the windows it names, at the largest size: the
    /// buttons stack, and New Game ends inside the viewport.
    func testNewGameIsWholeInTheIssuesWindowsAtTheLargestSize() {
        for viewport in [Self.iPhone11Landscape, Self.duoClosedLandscape] {
            for title in Self.titles {
                let shows = showsLastPlayed(viewport, .accessibility5, title: title)
                let limit = titleLineLimit(viewport, .accessibility5, title: title)
                XCTAssertEqual(caption(viewport, .accessibility5).arrangement, .column)
                let bottom = Self.padding + drawnButtonsBottom(viewport, .accessibility5, lastPlayed: shows,
                                                               title: title, titleLineLimit: limit)
                XCTAssertLessThanOrEqual(bottom, viewport.height,
                                         "\(title) in \(viewport.contentWidth)x\(viewport.height): New Game ends at "
                                         + "\(bottom), cap \(limit.map(String.init) ?? "none")")
            }
        }
    }

    // MARK: The rule on its own

    func testAnUnmeasuredViewportOrGaugeLeavesTheTitleUncapped() {
        XCTAssertNil(ShelfHeroLayout.sideBySideTitleLineLimit(
            viewportHeight: 0, contentPadding: 16, titleLines: 9, titleFirstLine: 30, titleLineStep: 30,
            buttonHeight: 44, newGameButtonHeight: 44,
            buttonArrangement: .row))
        XCTAssertNil(ShelfHeroLayout.sideBySideTitleLineLimit(
            viewportHeight: 220, contentPadding: 16, titleLines: 9, titleFirstLine: 0, titleLineStep: 0,
            buttonHeight: 44, newGameButtonHeight: 44,
            buttonArrangement: .row))
    }

    func testTheTitleCapLeavesContinueOnTheViewportAndNeverGoesBelowOneLine() {
        // Below the title: 6 + 8 + 44 = 58, so 220 - 16 - 58 = 146 pt of title.
        // Lines: 31, then 29 each: 4 lines are 118, 5 are 147.
        func cap(_ lines: Int, viewport: CGFloat = 220) -> Int? {
            ShelfHeroLayout.sideBySideTitleLineLimit(
                viewportHeight: viewport, contentPadding: 16, titleLines: lines,
                titleFirstLine: 31, titleLineStep: 29, buttonHeight: 44, newGameButtonHeight: 44,
                buttonArrangement: .row)
        }
        XCTAssertNil(cap(4))
        XCTAssertEqual(cap(5), 4)
        XCTAssertEqual(cap(9), 4)
        // Exactly on the viewport fits: 5 lines in 221.
        XCTAssertNil(cap(5, viewport: 221))
        XCTAssertEqual(cap(6, viewport: 221), 5)
        // No room at all still keeps one line.
        XCTAssertEqual(cap(9, viewport: 60), 1)
        // A title of one line is never capped.
        XCTAssertNil(cap(1, viewport: 60))
    }

    func testATitleIsItsFirstLineAndAStepForEachLineAfter() {
        XCTAssertEqual(ShelfHeroLayout.titleHeight(lines: 1, firstLine: 67, lineStep: 66), 67)
        XCTAssertEqual(ShelfHeroLayout.titleHeight(lines: 3, firstLine: 67, lineStep: 66), 199)
        XCTAssertEqual(ShelfHeroLayout.titleHeight(lines: 0, firstLine: 67, lineStep: 66), 0)
    }

    func testAnUnmeasuredViewportKeepsTheLine() {
        XCTAssertTrue(ShelfHeroLayout.sideBySideCaptionShowsLastPlayed(
            viewportHeight: 0, contentPadding: 16, titleHeight: 500, lastPlayedHeight: 500, buttonHeight: 500,
            newGameButtonHeight: 500,
            buttonArrangement: .column))
    }

    func testTheLineIsKeptWhenContinueEndsExactlyOnTheViewport() {
        // 16 + 100 + (40 + 6) + 6 + 8 + 44 = 220
        XCTAssertTrue(ShelfHeroLayout.sideBySideCaptionShowsLastPlayed(
            viewportHeight: 220, contentPadding: 16, titleHeight: 100, lastPlayedHeight: 40, buttonHeight: 44,
            newGameButtonHeight: 44,
            buttonArrangement: .row))
        XCTAssertFalse(ShelfHeroLayout.sideBySideCaptionShowsLastPlayed(
            viewportHeight: 219.5, contentPadding: 16, titleHeight: 100, lastPlayedHeight: 40, buttonHeight: 44,
            newGameButtonHeight: 44,
            buttonArrangement: .row))
    }

    /// Stacked, the buttons end a gap and a button below Continue, and that
    /// is what the title is capped for (issue #547).
    func testStackedTheTitleCapLeavesNewGameOnTheViewport() {
        // Below the title: 6 + 8 + 44 + 8 + 44 = 110, so 272 - 16 - 110 =
        // 146 pt of title. Lines: 31, then 29 each: 4 lines are 118, 5 are 147.
        func cap(_ lines: Int, viewport: CGFloat = 272) -> Int? {
            ShelfHeroLayout.sideBySideTitleLineLimit(
                viewportHeight: viewport, contentPadding: 16, titleLines: lines,
                titleFirstLine: 31, titleLineStep: 29, buttonHeight: 44, newGameButtonHeight: 44,
                buttonArrangement: .column)
        }
        XCTAssertNil(cap(4))
        XCTAssertEqual(cap(5), 4)
        XCTAssertNil(cap(5, viewport: 273))
        // 95 pt of title: three lines, where the row's rule keeps five.
        XCTAssertEqual(cap(6, viewport: 221), 3)
        XCTAssertEqual(cap(9, viewport: 60), 1)
    }

    func testStackedTheLineIsKeptWhenNewGameEndsExactlyOnTheViewport() {
        // 16 + 100 + (40 + 6) + 6 + 8 + 44 + 8 + 44 = 272
        XCTAssertTrue(ShelfHeroLayout.sideBySideCaptionShowsLastPlayed(
            viewportHeight: 272, contentPadding: 16, titleHeight: 100, lastPlayedHeight: 40, buttonHeight: 44,
            newGameButtonHeight: 44,
            buttonArrangement: .column))
        // Continue still fits here; New Game does not, so the line goes.
        XCTAssertFalse(ShelfHeroLayout.sideBySideCaptionShowsLastPlayed(
            viewportHeight: 271.5, contentPadding: 16, titleHeight: 100, lastPlayedHeight: 40, buttonHeight: 44,
            newGameButtonHeight: 44,
            buttonArrangement: .column))
    }

    /// New Game is the bound only where it fits under a one-line title with
    /// no line: 16 + 31 + 6 + 8 + 44 + 8 + 43 = 156.
    func testNewGameIsTheBoundOnlyWhereItCanFit() {
        func bound(_ viewport: CGFloat, firstLine: CGFloat = 31,
                   _ arrangement: ShelfHeroLayout.ButtonArrangement = .column) -> ShelfHeroLayout.ButtonArrangement {
            ShelfHeroLayout.sideBySideBoundArrangement(
                viewportHeight: viewport, contentPadding: 16, titleFirstLine: firstLine,
                buttonHeight: 44, newGameButtonHeight: 43, buttonArrangement: arrangement)
        }
        XCTAssertEqual(bound(156), .column)
        XCTAssertEqual(bound(155.5), .row)
        XCTAssertEqual(bound(500, .row), .row)
        // Unmeasured: `main`'s bound.
        XCTAssertEqual(bound(0), .row)
        XCTAssertEqual(bound(500, firstLine: 0), .row)
    }

    func testTheButtonsEndWithContinueInARowAndAButtonBelowItInAColumn() {
        let row = ShelfHeroLayout.sideBySideButtonsBottom(titleHeight: 100, lastPlayedHeight: 40,
                                                          buttonHeight: 44, newGameButtonHeight: 43,
                                                          buttonArrangement: .row)
        let column = ShelfHeroLayout.sideBySideButtonsBottom(titleHeight: 100, lastPlayedHeight: 40,
                                                             buttonHeight: 44, newGameButtonHeight: 43,
                                                             buttonArrangement: .column)
        XCTAssertEqual(row, ShelfHeroLayout.sideBySideContinueBottom(titleHeight: 100, lastPlayedHeight: 40,
                                                                     buttonHeight: 44))
        // New Game is its own height, here a point shorter than Continue.
        XCTAssertEqual(column, row + ShelfHeroLayout.buttonColumnSpacing + 43)
    }
}
