import SwiftUI
import UIKit
import XCTest
@testable import Waddle

/// Issue #353: on an iPhone Duo both bundled games' tiles read the same,
/// because their titles were cut before the digit that tells them apart.
///
/// Two rules fix it and both are checked here against the measured widths:
/// the title may shrink a little before it truncates
/// (`PlayableTileLayout.titleMinimumScaleFactor`), and a wide window gets
/// fewer, wider tiles (`Theme.gridMinimumTileWidth(for:contentWidth:)`).
///
/// These are arithmetic, and arithmetic cannot see a screen
/// (`docs/learnings/geometry-tests-cannot-see-the-screen.md`). What they can
/// do is measure the real title in the real font against the width the tile
/// gives it, which is the quantity that decides truncation. The look itself
/// was checked on the simulator; see the pull request.
final class WideGridLayoutTests: XCTestCase {

    private static let spacing: CGFloat = 20

    /// The shelf's content width (window, less the system's status column
    /// where there is one, less 16 pt of padding each side) on the shapes
    /// this issue is about. The Duo figures are from simulator captures of
    /// 2026-11-09: tiles of 162 pt in two columns closed, 151 pt in five open.
    private enum Content {
        static let iPhoneMini: CGFloat = 328        // 360 pt window
        static let iPhone17Pro: CGFloat = 370       // 402
        static let iPhone17ProMax: CGFloat = 408    // 440
        static let duoClosed: CGFloat = 344         // 466, 90 pt status column
        static let duoClosedLandscape: CGFloat = 562 // 678, 84 pt status column
        static let duoOpenRotated: CGFloat = 637    // 669, status bar on top
        static let duoOpen: CGFloat = 835           // 951, 84 pt status column
        static let iPadPro13Portrait: CGFloat = 1000 // 1032
    }

    private func columns(_ contentWidth: CGFloat, size: DynamicTypeSize = .large) -> Int {
        ShelfHeroLayout.gridColumnCount(
            contentWidth: contentWidth,
            minimum: Theme.gridMinimumTileWidth(for: size, contentWidth: contentWidth),
            spacing: Self.spacing)
    }

    private func tileWidth(_ contentWidth: CGFloat, size: DynamicTypeSize = .large) -> CGFloat {
        ShelfHeroLayout.gridColumnWidth(
            contentWidth: contentWidth,
            minimum: Theme.gridMinimumTileWidth(for: size, contentWidth: contentWidth),
            spacing: Self.spacing)
    }

    /// The tile title's width in the font the tile draws it in, at the
    /// default text size: `.headline`, which is what
    /// `Theme.Typography.tileTitle` is.
    private func titleWidth(_ name: String) -> CGFloat {
        let font = UIFont.preferredFont(
            forTextStyle: .headline,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        return (name as NSString).size(withAttributes: [.font: font]).width
    }

    /// The scale a title needs to fit a tile of `width` on one line: 1.0 or
    /// more means it fits at full size.
    private func scaleNeeded(for name: String, tileWidth width: CGFloat) -> CGFloat {
        (width - PlayableTileLayout.scrimHorizontalPadding * 2) / titleWidth(name)
    }

    private static let bundled = ["Freedoom Phase 1", "Freedoom Phase 2"]

    // MARK: The defect

    /// The measurement the issue rests on, kept in the suite so the cases
    /// below are known to be testing something: at the phone floor, neither
    /// Duo tile is wide enough for the bundled titles at full size.
    func testAtThePhoneFloorTheDuoTilesAreTooNarrowForTheBundledTitles() {
        for content in [Content.duoClosed, Content.duoOpen] {
            let width = ShelfHeroLayout.gridColumnWidth(
                contentWidth: content, minimum: Theme.gridMinimumTileWidth(for: .large),
                spacing: Self.spacing)
            for name in Self.bundled {
                XCTAssertLessThan(scaleNeeded(for: name, tileWidth: width), 1.0,
                                  "\(name) was expected not to fit a \(width) pt tile")
            }
        }
    }

    // MARK: Rule one, the title shrinks before it truncates

    /// Wherever the grid keeps two phone-sized columns, the bundled titles
    /// fit within the shrink the tile allows: the closed Duo and the
    /// narrowest phone, which has the same problem and was never reported.
    func testTheBundledTitlesFitNarrowTilesWithinTheAllowedShrink() {
        for content in [Content.duoClosed, Content.iPhoneMini] {
            let width = tileWidth(content)
            for name in Self.bundled {
                let needed = scaleNeeded(for: name, tileWidth: width)
                XCTAssertGreaterThanOrEqual(needed, PlayableTileLayout.titleMinimumScaleFactor,
                                            "\(name) still truncates on a \(width) pt tile: needs \(needed)")
            }
        }
    }

    /// The shrink is a small one. A floor low enough to fit any name would
    /// turn long titles into fine print; those are meant to truncate.
    func testTheShrinkStaysATitleAndLongNamesStillTruncate() {
        XCTAssertGreaterThanOrEqual(PlayableTileLayout.titleMinimumScaleFactor, 0.8)
        XCTAssertLessThan(PlayableTileLayout.titleMinimumScaleFactor, 1.0)
        XCTAssertLessThan(scaleNeeded(for: "Freedoom Phase 2 + SCYTHE", tileWidth: tileWidth(Content.duoClosed)),
                          PlayableTileLayout.titleMinimumScaleFactor)
    }

    // MARK: Rule two, a wide window gets wider tiles

    /// The open Duo: four tiles, each wide enough for the bundled titles at
    /// full size with no shrink at all.
    func testTheOpenDuoGetsFourTilesThatFitTheTitlesAtFullSize() {
        XCTAssertEqual(columns(Content.duoOpen), 4)
        let width = tileWidth(Content.duoOpen)
        XCTAssertEqual(width, 193.75, accuracy: 0.001)
        for name in Self.bundled {
            XCTAssertGreaterThanOrEqual(scaleNeeded(for: name, tileWidth: width), 1.0,
                                        "\(name) does not fit a \(width) pt tile at full size")
        }
    }

    /// Every wide window this repo ships to resolves to tiles that fit the
    /// bundled titles at full size.
    func testEveryWideWindowFitsTheTitlesAtFullSize() {
        for content in [Content.duoOpenRotated, Content.duoOpen, Content.iPadPro13Portrait] {
            let width = tileWidth(content)
            for name in Self.bundled {
                XCTAssertGreaterThanOrEqual(scaleNeeded(for: name, tileWidth: width), 1.0,
                                            "\(name) on a \(width) pt tile at content width \(content)")
            }
        }
    }

    // MARK: What must not move

    /// Phones and the closed Duo, in both orientations, keep the floor and
    /// the column counts they have today.
    func testPhoneSizedWindowsKeepThePhoneFloorAndTheirColumns() {
        let expected: [(CGFloat, Int)] = [
            (Content.iPhoneMini, 2), (Content.iPhone17Pro, 2), (Content.iPhone17ProMax, 2),
            (Content.duoClosed, 2), (Content.duoClosedLandscape, 3),
        ]
        for (content, count) in expected {
            XCTAssertEqual(Theme.gridMinimumTileWidth(for: .large, contentWidth: content),
                           Theme.gridMinimumTileWidth(for: .large), "floor moved at \(content)")
            XCTAssertEqual(columns(content), count, "columns changed at \(content)")
        }
    }

    /// The open Duo rotated is above the threshold and keeps its three
    /// columns: the wide floor changes nothing there.
    func testTheOpenRotatedDuoKeepsItsThreeColumns() {
        XCTAssertEqual(columns(Content.duoOpenRotated), 3)
        XCTAssertEqual(ShelfHeroLayout.gridColumnCount(
            contentWidth: Content.duoOpenRotated,
            minimum: Theme.gridMinimumTileWidth(for: .large), spacing: Self.spacing), 3)
    }

    /// A width the shelf has not measured yet is zero, and takes the phone
    /// floor rather than guessing wide.
    func testAnUnmeasuredWidthTakesThePhoneFloor() {
        XCTAssertEqual(Theme.gridMinimumTileWidth(for: .large, contentWidth: 0),
                       Theme.gridMinimumTileWidth(for: .large))
    }

    /// Accessibility text sizes keep their own, larger floor at every width:
    /// "drops columns rather than shrinking text" still holds on a wide window.
    func testAccessibilitySizesKeepTheirFloorOnAWideWindow() {
        for content in [Content.duoClosed, Content.duoOpen, Content.iPadPro13Portrait] {
            XCTAssertEqual(Theme.gridMinimumTileWidth(for: .accessibility3, contentWidth: content),
                           Theme.gridMinimumTileWidth(for: .accessibility3))
        }
    }

    // MARK: The row under the Continue hero

    /// Wider tiles are taller, and the stacked hero only ever left a 120 pt
    /// peek of the first row. On the open Duo that put the row's bottom edge,
    /// where the title is, under the fold. A wide window keeps the whole row.
    func testTheStackedHeroLeavesTheWholeFirstRowOnAWideWindow() {
        // The open Duo's viewport as the shelf measures it: the hero art was
        // capped at 343 pt there with the 120 pt peek, 60 pt of caption and
        // 32 pt of section spacing, so the viewport is 555 pt.
        let viewport: CGFloat = 555
        let padding: CGFloat = 16 // the shelf's inset, above the hero
        let caption = ShelfHeroLayout.defaultCaptionHeight
        let minimum = Theme.gridMinimumTileWidth(for: .large, contentWidth: Content.duoOpen)
        let rowHeight = tileWidth(Content.duoOpen) / Theme.tileAspectRatio

        let peek = ShelfHeroLayout.gridPeek(contentWidth: Content.duoOpen, tileMinimumWidth: minimum,
                                            gridSpacing: Self.spacing, contentPadding: padding)
        XCTAssertEqual(peek, rowHeight + padding, accuracy: 0.001)

        // Where the row's bottom edge lands, from the top of the viewport:
        // the inset, the art, the caption, the gap, then the row itself.
        func rowBottom(artHeight: CGFloat) -> CGFloat {
            padding + artHeight + caption + ShelfHeroLayout.sectionSpacing + rowHeight
        }
        let art = ShelfHeroLayout.artHeight(contentWidth: Content.duoOpen, viewportHeight: viewport,
                                            captionHeight: caption, gridPeek: peek)
        XCTAssertLessThanOrEqual(rowBottom(artHeight: art), viewport + 0.001,
                                 "the first tile row ends below the fold")

        // The discrimination: with the phone's peek the same row does not fit,
        // and neither does it with the row's height reserved but not the inset.
        let old = ShelfHeroLayout.artHeight(contentWidth: Content.duoOpen, viewportHeight: viewport,
                                            captionHeight: caption)
        XCTAssertGreaterThan(rowBottom(artHeight: old), viewport)
        let rowOnly = ShelfHeroLayout.artHeight(contentWidth: Content.duoOpen, viewportHeight: viewport,
                                                captionHeight: caption, gridPeek: rowHeight)
        XCTAssertGreaterThan(rowBottom(artHeight: rowOnly), viewport)
    }

    /// Phone-sized windows keep the peek, and so the hero, they have today.
    func testPhoneSizedWindowsKeepTheMinimumPeek() {
        for content in [Content.iPhoneMini, Content.iPhone17Pro, Content.iPhone17ProMax,
                        Content.duoClosed, Content.duoClosedLandscape] {
            XCTAssertEqual(ShelfHeroLayout.gridPeek(
                contentWidth: content,
                tileMinimumWidth: Theme.gridMinimumTileWidth(for: .large, contentWidth: content),
                gridSpacing: Self.spacing, contentPadding: 16),
                           ShelfHeroLayout.minimumGridPeek, "peek moved at \(content)")
        }
    }

    // MARK: The threshold

    /// Crossing the threshold changes no layout: just below it and at it the
    /// grid has the same number of columns. A threshold picked without this
    /// property makes a window dragged across it jump between a row of small
    /// tiles and two very large ones.
    func testCrossingTheThresholdDoesNotChangeTheColumnCount() {
        let threshold = Theme.wideGridContentWidth
        XCTAssertEqual(columns(threshold - 0.5), columns(threshold))
        XCTAssertEqual(columns(threshold - 0.5), 3)
    }

    /// Widening the window never takes a column away once it is wide, and
    /// never yields a tile under the wide floor.
    func testAboveTheThresholdColumnsNeverDecreaseAsTheWindowWidens() {
        var previous = columns(Theme.wideGridContentWidth)
        var width = Theme.wideGridContentWidth
        while width <= 1400 {
            let count = columns(width)
            XCTAssertGreaterThanOrEqual(count, previous, "lost a column at \(width)")
            XCTAssertGreaterThanOrEqual(tileWidth(width), Theme.wideGridMinimumTileWidth - 0.001,
                                        "tile under the wide floor at \(width)")
            previous = count
            width += 1
        }
    }
}
