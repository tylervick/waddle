import SwiftUI
import UIKit
import XCTest
@testable import Waddle

/// Issues #426 and #431: a shelf tile at the large text sizes.
///
/// #426: from one Dynamic Type step above the default, both bundled games'
/// tiles read "Freedoom Ph…", because the one-line title can shrink to 0.85 of
/// its size and needed about 0.7. #431: at an accessibility size on a closed
/// iPhone Duo held on its side the grid is one column, and a tile of that
/// width at 4:3 is taller than the window, so its title is under the fold.
///
/// Two rules fix them, and both are arithmetic that is checked here against
/// the real font: above the default size the title has a second line
/// (`PlayableTileLayout.titleLineLimit`), and a tile is never taller than
/// the viewport less the shelf's insets
/// (`PlayableTileLayout.tileHeight(width:viewportHeight:contentPadding:)`).
///
/// Arithmetic cannot see a screen
/// (`docs/learnings/geometry-tests-cannot-see-the-screen.md`). The captures
/// that can are in the pull request.
final class ShelfTileLargeTextTests: XCTestCase {

    private static let spacing: CGFloat = 20
    private static let padding: CGFloat = 16

    /// The closed iPhone Duo as the shelf measures it. The content widths are
    /// `WideGridLayoutTests`' (measured 2026-11-09). The landscape viewport
    /// is measured too (2026-11-21, iOS 27.1, off a capture of the capped
    /// tile, which is the viewport less 32 pt): the 466 pt window less 82 pt
    /// of bar above the scroll view and 34 pt below it.
    private static let duoClosed = Viewport(contentWidth: 344, height: 620)
    private static let duoClosedLandscape = Viewport(contentWidth: 562, height: 350)

    private static let bundled = ["Freedoom Phase 1", "Freedoom Phase 2"]

    /// Every size above the default, which is where the title has two lines.
    private static let largerSizes = DynamicTypeSize.allCases.filter { $0 > .large }

    private func category(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }

    /// The tile title's font at a text size: the UIKit style
    /// `Theme.Typography.tileTitleStyle` names, which is what the tile's
    /// `WholeWordText` measures with.
    private func titleFont(_ size: DynamicTypeSize) -> UIFont {
        UIFont.preferredFont(forTextStyle: Theme.Typography.tileTitleStyle,
                             compatibleWith: UITraitCollection(preferredContentSizeCategory: category(size)))
    }

    private func width(_ string: String, _ size: DynamicTypeSize) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: titleFont(size)]).width
    }

    private func tileWidth(_ viewport: Viewport, _ size: DynamicTypeSize) -> CGFloat {
        ShelfHeroLayout.gridColumnWidth(
            contentWidth: viewport.contentWidth,
            minimum: Theme.gridMinimumTileWidth(for: size, contentWidth: viewport.contentWidth),
            spacing: Self.spacing)
    }

    /// The line a tile gives its title: its width less the scrim's insets.
    private func titleLine(_ viewport: Viewport, _ size: DynamicTypeSize) -> CGFloat {
        tileWidth(viewport, size) - PlayableTileLayout.scrimHorizontalPadding * 2
    }

    /// How many lines a title takes in a line of `line` points when it is
    /// broken only between words, as `WholeWordText` breaks it. Nil when a
    /// word alone is wider than the line.
    private func lines(_ title: String, in line: CGFloat, _ size: DynamicTypeSize) -> Int? {
        let space = width(" ", size)
        var count = 1
        var used: CGFloat = 0
        for word in title.split(separator: " ").map(String.init) {
            let wordWidth = width(word, size)
            guard wordWidth <= line else { return nil }
            if used == 0 {
                used = wordWidth
            } else if used + space + wordWidth <= line {
                used += space + wordWidth
            } else {
                count += 1
                used = wordWidth
            }
        }
        return count
    }

    private func tileHeight(_ viewport: Viewport, _ size: DynamicTypeSize) -> CGFloat {
        PlayableTileLayout.tileHeight(width: tileWidth(viewport, size),
                                      viewportHeight: viewport.height,
                                      contentPadding: Self.padding)
    }

    // MARK: #426, the defect

    /// What the issue measured, kept so the cases below are known to test
    /// something: on the closed Duo, both ways up, at the two sizes it names,
    /// the bundled titles need more shrink than one line allows.
    func testOneLineCannotHoldTheBundledTitlesAtTheLargeSizes() {
        let cases: [(Viewport, DynamicTypeSize)] = [
            (Self.duoClosed, .xxxLarge), (Self.duoClosedLandscape, .xxxLarge),
            (Self.duoClosed, .accessibility5),
        ]
        for (viewport, size) in cases {
            for name in Self.bundled {
                let needed = titleLine(viewport, size) / width(name, size)
                XCTAssertLessThan(needed, PlayableTileLayout.titleMinimumScaleFactor,
                                  "\(name) was expected not to fit one line at \(size) in \(viewport.contentWidth)")
            }
        }
    }

    // MARK: #426, the rule

    func testTheTitleHasOneLineUpToTheDefaultSizeAndTwoAboveIt() {
        XCTAssertEqual(PlayableTileLayout.titleLineLimit(largerThanDefaultText: false), 1)
        XCTAssertEqual(PlayableTileLayout.titleLineLimit(largerThanDefaultText: true), 2)
    }

    /// The second line is taken only where the one line cannot hold the
    /// name. On the open Duo, flat and turned, at the largest standard size
    /// the bundled titles still fit one line within the allowed shrink, and
    /// are drawn as they were; on the closed Duo they do not.
    func testTheOneLineTitleIsKeptWhereItStillFits() {
        let size = DynamicTypeSize.xxxLarge
        let open = [Viewport(contentWidth: 835, height: 555), Viewport(contentWidth: 637, height: 850)]
        for name in Self.bundled {
            let least = PlayableTileLayout.oneLineTitleMinimumWidth(
                shrunkWidth: PlayableTileTitle.shrunkWidth(of: name, at: size))
            for viewport in open {
                XCTAssertLessThanOrEqual(least, titleLine(viewport, size),
                                         "\(name) lost its one line in \(viewport.contentWidth)")
            }
            for viewport in [Self.duoClosed, Self.duoClosedLandscape] {
                XCTAssertGreaterThan(least, titleLine(viewport, size),
                                     "\(name) was expected to need a second line in \(viewport.contentWidth)")
            }
        }
    }

    /// On the closed Duo, upright and on its side, at every size above the
    /// default: each word of a bundled title fits the tile's line at full
    /// size, so nothing is shrunk or broken, and the whole title fits the
    /// lines it is allowed. The digit that tells the two games apart is
    /// therefore drawn.
    func testTheBundledTitlesFitTwoLinesOnTheClosedDuoAtEveryLargerSize() throws {
        for viewport in [Self.duoClosed, Self.duoClosedLandscape] {
            for size in Self.largerSizes {
                let line = titleLine(viewport, size)
                for name in Self.bundled {
                    let needed = try XCTUnwrap(
                        lines(name, in: line, size),
                        "a word of \(name) is wider than a \(line) pt line at \(size)")
                    XCTAssertLessThanOrEqual(
                        needed, PlayableTileLayout.titleLineLimit(largerThanDefaultText: true),
                        "\(name) needs \(needed) lines of \(line) pt at \(size)")
                }
            }
        }
    }

    /// The same on the phones: the narrowest supported one has the same
    /// two-column tile and the same titles.
    func testTheBundledTitlesFitTwoLinesOnEveryPhoneAtEveryLargerSize() throws {
        for device in SupportedDevice.allPhones {
            let viewport = Viewport(contentWidth: device.contentWidth, height: 0)
            for size in Self.largerSizes {
                let line = titleLine(viewport, size)
                for name in Self.bundled {
                    let needed = try XCTUnwrap(
                        lines(name, in: line, size),
                        "a word of \(name) is wider than a \(line) pt line at \(size) on \(device.name)")
                    XCTAssertLessThanOrEqual(needed, 2, "\(name) at \(size) on \(device.name)")
                }
            }
        }
    }

    // MARK: #431, the defect

    /// The window the issue is about: at every accessibility size the grid is
    /// one column there, and a tile of that width at its 4:3 shape is taller
    /// than the whole viewport.
    func testAFourByThreeTileIsTallerThanTheClosedLandscapeViewportAtAccessibilitySizes() {
        for size in DynamicTypeSize.allCases where size.isAccessibilitySize {
            let width = tileWidth(Self.duoClosedLandscape, size)
            XCTAssertEqual(width, Self.duoClosedLandscape.contentWidth, accuracy: 0.001,
                           "expected one column at \(size)")
            XCTAssertGreaterThan(width / Theme.tileAspectRatio, Self.duoClosedLandscape.height,
                                 "the 4:3 tile was expected not to fit at \(size)")
        }
    }

    // MARK: #431, the rule

    /// At every text size, in the 678x466 window, a tile scrolled to the top
    /// of the grid ends above the fold: the shelf's inset, the tile, and the
    /// same inset under it fit the viewport.
    func testATileFitsTheClosedLandscapeViewportAtEveryTextSize() {
        for size in DynamicTypeSize.allCases {
            let height = tileHeight(Self.duoClosedLandscape, size)
            XCTAssertLessThanOrEqual(Self.padding + height + Self.padding,
                                     Self.duoClosedLandscape.height + 0.001,
                                     "a tile is \(height) pt tall at \(size)")
        }
    }

    /// The shape the shelf hands a tile is the capped height's: the tile keeps
    /// its column's width and gives up height.
    func testTheCappedTileKeepsItsWidth() {
        let viewport = Self.duoClosedLandscape
        let width = tileWidth(viewport, .accessibility5)
        let ratio = PlayableTileLayout.tileAspectRatio(width: width, viewportHeight: viewport.height,
                                                       contentPadding: Self.padding)
        XCTAssertGreaterThan(ratio, Theme.tileAspectRatio)
        XCTAssertEqual(width / ratio, viewport.height - Self.padding * 2, accuracy: 0.001)
    }

    /// The title of a capped tile is still whole: the one-column tile there
    /// is wide, and its lines hold the bundled names at the largest size.
    func testTheCappedTilesTitleFitsUnderItsArt() throws {
        let viewport = Self.duoClosedLandscape
        let size = DynamicTypeSize.accessibility5
        let needed = try XCTUnwrap(lines("Freedoom Phase 2", in: titleLine(viewport, size), size))
        let scrim = PlayableTileLayout.scrimHeight(
            titleLineHeight: titleFont(size).lineHeight * CGFloat(needed))
        XCTAssertLessThan(scrim, tileHeight(viewport, size) * 0.5,
                          "the title covers half the tile or more")
    }

    // MARK: What must not move

    /// In the same window at the standard sizes the cap does not bind: three
    /// columns of 4:3 tiles, as before.
    func testTheStandardSizesKeepTheirShapeInTheClosedLandscapeWindow() {
        for size in DynamicTypeSize.allCases where !size.isAccessibilitySize {
            let width = tileWidth(Self.duoClosedLandscape, size)
            XCTAssertEqual(tileHeight(Self.duoClosedLandscape, size), width / Theme.tileAspectRatio,
                           accuracy: 0.001, "the tile changed shape at \(size)")
            XCTAssertEqual(PlayableTileLayout.tileAspectRatio(
                width: width, viewportHeight: Self.duoClosedLandscape.height,
                contentPadding: Self.padding), Theme.tileAspectRatio, accuracy: 0.0001)
        }
    }

    /// The closed Duo upright, the phones in portrait and a landscape phone
    /// keep the 4:3 tile at every text size.
    func testUprightAndPhoneWindowsKeepTheFourByThreeTileAtEveryTextSize() {
        let viewports = [Self.duoClosed, Viewport.portraitPhone,
                         Viewport.landscapePhone, Viewport.landscapeProPhone]
        for viewport in viewports {
            for size in DynamicTypeSize.allCases {
                let width = tileWidth(viewport, size)
                XCTAssertEqual(tileHeight(viewport, size), width / Theme.tileAspectRatio, accuracy: 0.001,
                               "the tile changed shape at \(size) in \(viewport.contentWidth)x\(viewport.height)")
            }
        }
    }

    /// A viewport that has not been measured yet is zero, and the tile keeps
    /// its shape rather than flashing a strip on the first frame.
    func testAnUnmeasuredViewportKeepsTheShape() {
        XCTAssertEqual(PlayableTileLayout.tileHeight(width: 562, viewportHeight: 0,
                                                     contentPadding: Self.padding),
                       562 / Theme.tileAspectRatio, accuracy: 0.001)
        XCTAssertEqual(PlayableTileLayout.tileAspectRatio(width: 562, viewportHeight: 0,
                                                          contentPadding: Self.padding),
                       Theme.tileAspectRatio, accuracy: 0.0001)
        XCTAssertEqual(PlayableTileLayout.tileAspectRatio(width: 0, viewportHeight: 350,
                                                          contentPadding: Self.padding),
                       Theme.tileAspectRatio, accuracy: 0.0001)
    }

    /// The cap stops at a floor: a window too short for that much tile gets
    /// the floor, not a strip, and a tile already shorter than the floor is
    /// left alone.
    func testTheCapStopsAtItsFloor() {
        XCTAssertEqual(PlayableTileLayout.tileHeight(width: 562, viewportHeight: 100,
                                                     contentPadding: Self.padding),
                       PlayableTileLayout.minimumCappedTileHeight, accuracy: 0.001)
        XCTAssertEqual(PlayableTileLayout.tileHeight(width: 120, viewportHeight: 100,
                                                     contentPadding: Self.padding),
                       90, accuracy: 0.001)
    }

    // MARK: The fold budget reads the same height

    /// The hero zone's budget is spent against the row the shelf draws. In
    /// the capped window that is the capped tile, so the budget is what the
    /// zone break leaves and not the 4:3 row's much larger deficit.
    func testTheHeroZoneBudgetUsesTheCappedRow() {
        let viewport = Self.duoClosedLandscape
        let minimum = Theme.gridMinimumTileWidth(for: .accessibility5, contentWidth: viewport.contentWidth)
        let budget = ShelfHeroLayout.heroZoneBudget(
            viewportHeight: viewport.height, contentWidth: viewport.contentWidth,
            tileMinimumWidth: minimum, contentPadding: Self.padding,
            gridSpacing: Self.spacing, compactHeight: true)
        XCTAssertEqual(budget, -ShelfHeroLayout.sectionSpacing(compactHeight: true), accuracy: 0.001)
    }

    /// And the wide window's whole-row peek is the capped row's too, when it
    /// is told the viewport; without one it is the 4:3 row, as before.
    func testTheWideGridPeekUsesTheCappedRowWhenGivenAViewport() {
        let content: CGFloat = 640
        let minimum = Theme.gridMinimumTileWidth(for: .accessibility5, contentWidth: content)
        let uncapped = ShelfHeroLayout.gridPeek(contentWidth: content, tileMinimumWidth: minimum,
                                                gridSpacing: Self.spacing, contentPadding: Self.padding)
        XCTAssertEqual(uncapped, content / Theme.tileAspectRatio + Self.padding, accuracy: 0.001)
        let capped = ShelfHeroLayout.gridPeek(contentWidth: content, tileMinimumWidth: minimum,
                                              gridSpacing: Self.spacing, contentPadding: Self.padding,
                                              viewportHeight: 350)
        XCTAssertEqual(capped, 350 - Self.padding, accuracy: 0.001)
    }
}
