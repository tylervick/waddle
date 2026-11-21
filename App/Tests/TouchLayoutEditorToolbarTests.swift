import SwiftUI
import UIKit
import XCTest
@testable import Waddle

/// The layout editor's Cancel / Reset / Done toolbar at every text size
/// (issue #422). In the band between MAP and MENU of a closed iPhone Duo the
/// three words used to share one squeezed row, and at the largest
/// accessibility size each broke two letters to a line.
///
/// The toolbar is measured as SwiftUI lays it out, in a hosting controller,
/// with the text size set in the environment so the answer does not follow
/// the simulator's own setting. What a whole word needs is measured
/// separately, from `UIFont`, and the two are compared: a toolbar one line
/// tall cannot have broken a word, and a taller one must be exactly as wide
/// as its widest whole word needs. The squeezed row was neither (204 pt tall
/// and 251 pt wide where the widest word needs about 190).
@MainActor
final class TouchLayoutEditorToolbarTests: XCTestCase {

    /// The safe area of a closed iPhone Duo held upright, the window the
    /// issue was measured in: 466x678 less the status column on the trailing
    /// edge. The column's width only narrows the band, so the layout's own
    /// figure for a full 466 pt is checked as well.
    private static let closedDuoSafeAreas = [CGSize(width: 382, height: 678),
                                             CGSize(width: 466, height: 678)]

    private func fittedSize(_ size: DynamicTypeSize, offered width: CGFloat) -> CGSize {
        let toolbar = TouchLayoutEditorToolbar(cancel: {}, reset: {}, done: {})
            .environment(\.dynamicTypeSize, size)
        let host = UIHostingController(rootView: toolbar)
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    /// The width each word needs on one line at `size`, and the line's height.
    private func words(_ size: DynamicTypeSize) -> (widths: [CGFloat], lineHeight: CGFloat) {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        let semibold = UIFont.systemFont(ofSize: body.pointSize, weight: .semibold)
        func width(_ word: String, _ font: UIFont) -> CGFloat {
            ceil((word as NSString).size(withAttributes: [.font: font]).width)
        }
        return ([width("Cancel", body), width("Reset", body), width("Done", semibold)],
                body.lineHeight)
    }

    /// The test's own foundation: the environment's text size reaches the
    /// hosted toolbar. If it did not, every size below would measure the
    /// same toolbar and prove nothing.
    func testTheHostedToolbarFollowsTheTextSizeItIsGiven() {
        let small = fittedSize(.large, offered: 2000)
        let huge = fittedSize(.accessibility5, offered: 2000)
        XCTAssertGreaterThan(huge.width, small.width * 1.5)
        XCTAssertGreaterThan(huge.height, small.height * 1.5)
    }

    /// The property the issue asks for: at every text size, in the band a
    /// closed Duo leaves between MAP and MENU, no word is broken and the
    /// toolbar stays inside the band.
    func testNoWordIsBrokenAtAnyTextSizeOnAClosedDuo() {
        for safeArea in Self.closedDuoSafeAreas {
            let band = TouchLayoutEditorToolbar.availableWidth(in: safeArea)
            for size in DynamicTypeSize.allCases {
                let fitted = fittedSize(size, offered: band)
                let (widths, lineHeight) = words(size)
                let context = "\(size) in \(band) pt: toolbar \(fitted), words \(widths), line \(lineHeight)"
                let padding = TouchLayoutEditorToolbar.horizontalPadding * 2

                XCTAssertLessThanOrEqual(fitted.width, band + 0.5,
                                         "the toolbar is wider than the band between MAP and MENU: \(context)")

                if fitted.height < lineHeight * 1.5 + TouchLayoutEditorToolbar.verticalPadding * 2 {
                    // One line tall: a row, and as wide as three whole words.
                    let row = widths.reduce(0, +) + TouchLayoutEditorToolbar.rowSpacing * 2 + padding
                    XCTAssertEqual(fitted.width, row, accuracy: 6, "a row of other than whole words: \(context)")
                } else {
                    // Taller: it must be the column, as wide as its widest
                    // whole word and three lines tall. A squeezed row is
                    // wider than that and its words are in pieces.
                    let column = (widths.max() ?? 0) + padding
                    XCTAssertEqual(fitted.width, column, accuracy: 4,
                                   "taller than one line, and not a column of whole words: \(context)")
                    let height = lineHeight * 3 + TouchLayoutEditorToolbar.columnSpacing * 2
                        + TouchLayoutEditorToolbar.verticalPadding * 2
                    XCTAssertEqual(fitted.height, height, accuracy: 6,
                                   "a column of other than three lines: \(context)")
                }
            }
        }
    }

    /// Both arrangements are really used on a closed Duo: a row at the
    /// default size, where nothing was wrong and nothing should move, and
    /// the column at the largest accessibility size, where the row does not
    /// fit. Without this the test above could pass on a toolbar that is
    /// always a column.
    func testADefaultSizeRowAndALargestSizeColumn() {
        let band = TouchLayoutEditorToolbar.availableWidth(in: Self.closedDuoSafeAreas[0])
        let chrome = TouchLayoutEditorToolbar.verticalPadding * 2
        XCTAssertLessThan(fittedSize(.large, offered: band).height,
                          words(.large).lineHeight * 1.5 + chrome)
        XCTAssertGreaterThan(fittedSize(.accessibility5, offered: band).height,
                             words(.accessibility5).lineHeight * 2.5 + chrome)
    }

    /// Where there is room for the row it is used, whatever the text size:
    /// an open Duo held upright (951x669) has a band wider than the three
    /// words at the largest accessibility size.
    func testAWideWindowKeepsTheRowAtTheLargestTextSize() {
        let band = TouchLayoutEditorToolbar.availableWidth(in: CGSize(width: 867, height: 669))
        let fitted = fittedSize(.accessibility5, offered: band)
        XCTAssertLessThan(fitted.height, words(.accessibility5).lineHeight * 1.5
                          + TouchLayoutEditorToolbar.verticalPadding * 2)
        XCTAssertLessThanOrEqual(fitted.width, band + 0.5)
    }

    /// The width the toolbar is offered is the band between MAP and MENU as
    /// the overlay lays them out, less the clearance on each side, in the
    /// window the suite is really running in. So on each CI destination
    /// (phone, iPad, closed Duo) the toolbar is clear of both buttons with
    /// the safe area the system reports, not one typed into a fixture.
    func testTheOfferedWidthIsInsideTheLiveWindowsBand() throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = try XCTUnwrap(scenes.flatMap(\.windows).first(where: \.isKeyWindow)
                                   ?? scenes.flatMap(\.windows).first, "no window to measure")
        let usable = window.bounds.inset(by: window.safeAreaInsets)
        let layout = TouchOverlayLayout(bounds: window.bounds, safeAreaInsets: window.safeAreaInsets,
                                        hudReserve: 0)
        let offered = TouchLayoutEditorToolbar.availableWidth(in: usable.size)
        // The toolbar is centred in the safe area.
        let toolbar = CGRect(x: usable.midX - offered / 2, y: usable.minY, width: offered, height: 1)
        let context = "window \(window.bounds), insets \(window.safeAreaInsets), offered \(offered)"
        XCTAssertGreaterThanOrEqual(toolbar.minX - layout.defaultFrame(for: .automap).maxX,
                                    TouchLayoutEditorToolbar.clearance - 0.01, "too close to MAP: \(context)")
        XCTAssertGreaterThanOrEqual(layout.defaultFrame(for: .menu).minX - toolbar.maxX,
                                    TouchLayoutEditorToolbar.clearance - 0.01, "too close to MENU: \(context)")
    }
}
