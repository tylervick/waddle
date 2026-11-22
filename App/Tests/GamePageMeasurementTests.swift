import SwiftUI
import XCTest
@testable import Waddle

/// Nothing the game page measures of itself moves once it is taken (issue
/// #450).
///
/// `GamePageView` measures three things and lays its hero out from them: the
/// form (`artContentWidth`, `viewportHeight`), the hero row (`heroRowWidth`)
/// and a hidden copy of the caption's words (`captionWordWidth`). The shelf
/// did the first of those to a scroll view and a launch could spin for ever
/// (`docs/learnings/a-scroll-view-measured-to-lay-out-its-own-content-can-spin.md`).
///
/// The page's loop was the hero row. Measured off its own frame, the row was
/// read a quarter of a point wider stacked than side by side, and where the
/// rule that chooses between the two fell inside that quarter point the page
/// went back and forth: 383.25, 383.0, 383.25, 383.0, and side by side,
/// stacked, side by side, stacked (a game named as below with a Continue
/// save, `accessibility3`, a 423x284 window; iPhone 18 Pro simulator, iOS
/// 27.0, 2026-11-21). It is now the row's *offered* width that is measured
/// (`onOfferedWidthChange`).
///
/// A window on that threshold depends on the fonts, so the sizes are not
/// written down here. The test finds its own: windows where a third of a
/// point on the row's width changes the arrangement. Those are hosted, and
/// each measurement must have been taken once.
@MainActor
final class GamePageMeasurementTests: XCTestCase {
    private var seededGameIDs: [UUID] = []

    override func tearDown() async throws {
        for id in seededGameIDs {
            try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forGameID: id))
        }
        seededGameIDs = []
    }

    /// Every set of measurements the page reported, in order, hosted in a
    /// window of `size`.
    private func measurements(of game: Game, in library: LibraryService,
                              textSize: DynamicTypeSize, window size: CGSize) -> [GamePageMeasurements] {
        var reported: [GamePageMeasurements] = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            GamePageView(game: game, library: library,
                         onPlay: { _, _ in }, onChanged: {}, onClose: {})
        }
        .dynamicTypeSize(textSize)
        .environment(\.gamePageMeasurementsReport) { reported.append($0) })
        window.isHidden = false
        // Several turns: each measurement arrives a layout pass after the
        // state it follows from, and the loop took one pass a step.
        for _ in 0..<10 {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        window.isHidden = true
        window.rootViewController = nil
        return reported
    }

    /// Whether the arrangement turns on a third of a point of the row's
    /// width: a row that reports itself a hair wide is laid out one way and
    /// a row that does not, the other.
    private func onTheThreshold(contentWidth: CGFloat, viewportHeight: CGFloat,
                                captionWordWidth: CGFloat, rowWidth: CGFloat) -> Bool {
        func arrangement(rowWider excess: CGFloat) -> PlayableDetailLayout.HeroArrangement {
            PlayableDetailLayout.arrangement(contentWidth: contentWidth, viewportHeight: viewportHeight,
                                             minimumCaptionWidth: captionWordWidth, rowWidth: rowWidth + excess)
        }
        return arrangement(rowWider: 0) != arrangement(rowWider: 1.0 / 3.0)
    }

    /// The windows expected to be on the threshold, worked out from one
    /// hosted page: what the form and the row take off a window, and the
    /// caption's width, which is the same in every window.
    ///
    /// The row's inset is not the same in every window (40 pt of a 900 pt
    /// window, 32 pt of a 358 pt one), so the search is made with the
    /// form's inset as well, and each window found is checked against what
    /// the page really measured in it before it is counted.
    private func windowsNearTheThreshold(settled: GamePageMeasurements, in reference: CGSize) -> [CGSize] {
        guard let caption = settled.captionWordWidth else { return [] }
        let contentInset = reference.width - settled.artContentWidth
        let rowInsets = Set([reference.width - settled.heroRowWidth, contentInset])
        let chrome = reference.height - settled.viewportHeight
        var found: [CGSize] = []
        for height in stride(from: CGFloat(200), through: 800, by: 1) {
            for width in stride(from: CGFloat(300), through: 1300, by: 1)
            where rowInsets.contains(where: {
                onTheThreshold(contentWidth: width - contentInset, viewportHeight: height - chrome,
                               captionWordWidth: caption, rowWidth: width - $0)
            }) {
                found.append(CGSize(width: width, height: height))
            }
        }
        return found
    }

    func testNoMeasurementMovesWhereTheArrangementTurnsOnAFractionOfAPoint() throws {
        let fixture = ShelfPreviewFixture.continueHero()
        let game = try XCTUnwrap(try fixture.library.shelfGames().first)
        seededGameIDs.append(game.id)
        let reference = CGSize(width: 900, height: 400)
        var onThreshold = 0

        // The first name is the one the loop was found with; the bundled
        // name is what every install has.
        for name in ["Sigil II Extraordinarily Thunderstruck Wads", "Freedoom Phase 1"] {
            try fixture.library.rename(game, to: name)
            for textSize in [DynamicTypeSize.large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5] {
                let settled = try XCTUnwrap(
                    measurements(of: game, in: fixture.library, textSize: textSize, window: reference).last,
                    "the page reported nothing at \(textSize)")
                XCTAssertGreaterThan(settled.heroRowWidth, 0, "the hero row was never measured at \(textSize)")
                XCTAssertNotNil(settled.captionWordWidth, "the caption was never measured at \(textSize)")

                for window in windowsNearTheThreshold(settled: settled, in: reference).prefix(8) {
                    let reported = measurements(of: game, in: fixture.library, textSize: textSize, window: window)
                    let context = "\(name), \(textSize), \(window.width)x\(window.height): \(reported)"

                    // The page reports each change once, so a set of
                    // measurements seen twice is one it left and came back
                    // to: the cycle. A window's bars can settle a pass after
                    // the form is first measured (on an iPad the viewport
                    // was 113 and then 165, on a Duo the form 434 and then
                    // 346), and that is a change, not a return.
                    XCTAssertEqual(Set(reported).count, reported.count,
                                   "the page came back to measurements it had left. \(context)")

                    // The row's offer follows the form and nothing else, so
                    // for one width of form there is one width of row.
                    let rowsByForm = Dictionary(grouping: reported.filter { $0.heroRowWidth > 0 },
                                                by: \.artContentWidth)
                    for (form, measured) in rowsByForm {
                        XCTAssertEqual(Set(measured.map(\.heroRowWidth)).count, 1,
                                       "the hero row's width moved in a form \(form) pt wide. \(context)")
                    }

                    // A window is offered in whole points and insets come in
                    // whole or half points, so any other fraction on the row
                    // is the content's.
                    for row in reported.map(\.heroRowWidth) {
                        XCTAssertEqual(row * 2, (row * 2).rounded(), accuracy: 0.0001,
                                       "the hero row was measured at something other than its offer. \(context)")
                    }

                    // The caption's words are a fixed-size copy: one width.
                    XCTAssertLessThanOrEqual(Set(reported.compactMap(\.captionWordWidth)).count, 1,
                                             "the caption's width moved after it was taken. \(context)")

                    if let last = reported.last, let caption = last.captionWordWidth,
                       onTheThreshold(contentWidth: last.artContentWidth, viewportHeight: last.viewportHeight,
                                      captionWordWidth: caption, rowWidth: last.heroRowWidth.rounded(.down)) {
                        onThreshold += 1
                    }

                }
            }
        }
        XCTAssertGreaterThan(onThreshold, 0, "no window hosted was on the threshold, so nothing was tested")
    }
}
