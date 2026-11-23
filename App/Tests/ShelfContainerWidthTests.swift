import SwiftUI
import XCTest
@testable import Waddle

/// The real shelf holds its content to its container's width (issues #437
/// and #450).
///
/// `ScrollContentWidthTests` shows what `OfferedWidthScrollView` does, on a
/// scroll view of its own. This hosts `ShelfView` itself, so that building
/// the shelf on another scroll view fails here and not on an open iPhone Duo
/// at the largest text size, or beside its panel (issue #469).
///
/// The shelf is put in a window too narrow for what it holds. Its content
/// then reports wider than it is offered, by a lot and without a loop, and a
/// scroll view follows that: with the modifier deleted, the scroll view in a
/// 120 pt window was 269 pt wide (iPhone 18 Pro simulator, iOS 27.0,
/// 2026-11-21; the same with the modifier moved onto the `ScrollView`). Built
/// on the offer, the scroll view and its content are the window's width at
/// every size below.
@MainActor
final class ShelfContainerWidthTests: XCTestCase {
    /// Narrower than the shelf's content can be: a Continue hero's buttons
    /// at the largest text size, or a tile's floor.
    private static let widths: [CGFloat] = [60, 120, 200]
    private static let height: CGFloat = 951

    private var seededGameIDs: [UUID] = []

    override func tearDown() async throws {
        for id in seededGameIDs {
            try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forGameID: id))
        }
        seededGameIDs = []
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        if let scroll = view as? UIScrollView { found.append(scroll) }
        for sub in view.subviews { found += scrollViews(in: sub) }
        return found
    }

    private struct Scroll {
        /// In the window's coordinates.
        var frame: CGRect
        var contentSize: CGSize
        /// The scroll view's safe area at the sides, which the content's
        /// container does not include: 88 pt on an iPhone Duo, where the
        /// content of a 120 pt scroll view is 32 pt wide.
        var sideInsets: CGFloat
    }

    /// Each scroll view the hosted shelf made.
    private func shelfScrollViews(continueHero: Bool, width: CGFloat,
                                  laidOutFirstAt firstWidth: CGFloat? = nil) throws -> [Scroll] {
        let fixture = continueHero ? ShelfPreviewFixture.continueHero() : ShelfPreviewFixture.factory()
        if continueHero, let played = try fixture.library.recentlyPlayed(limit: 1).first {
            seededGameIDs.append(played.id)
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: firstWidth ?? width, height: Self.height))
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ShelfView(library: fixture.library, importer: fixture.importer,
                      lastExitCode: .constant(nil), panelModel: ShelfPanelModel())
        }.dynamicTypeSize(.accessibility5))
        window.isHidden = false
        // Several turns: the shelf loads its games on appearing, and sizes
        // its hero a layout pass after it is measured.
        func settle() {
            for _ in 0..<20 {
                window.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        settle()
        if firstWidth != nil {
            window.frame = CGRect(x: 0, y: 0, width: width, height: Self.height)
            settle()
        }
        let found = scrollViews(in: window).map {
            Scroll(frame: $0.convert($0.bounds, to: window), contentSize: $0.contentSize,
                   sideInsets: $0.safeAreaInsets.left + $0.safeAreaInsets.right)
        }
        window.isHidden = true
        window.rootViewController = nil
        return found
    }

    private func assertHeldToTheWindow(continueHero: Bool, widths: [CGFloat] = widths,
                                       laidOutFirstAt firstWidth: CGFloat? = nil,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        var checked = 0
        for width in widths {
            let scrolls = try shelfScrollViews(continueHero: continueHero, width: width,
                                               laidOutFirstAt: firstWidth)
            XCTAssertEqual(scrolls.count, 1, "the shelf is one scroll view; found \(scrolls) at \(width) pt",
                           file: file, line: line)
            // A window with no room between its insets has no width to hold
            // anything to: 60 pt on a Duo, whose insets are 88.
            for scroll in scrolls where scroll.sideInsets < width {
                checked += 1
                XCTAssertEqual(scroll.frame.minX, 0, accuracy: 0.0001,
                               "at \(width) pt the shelf's scroll view is \(scroll)", file: file, line: line)
                XCTAssertEqual(scroll.frame.width, width, accuracy: 0.0001,
                               "at \(width) pt the shelf's scroll view followed its content: \(scroll)",
                               file: file, line: line)
                XCTAssertEqual(scroll.contentSize.width, width - scroll.sideInsets, accuracy: 0.0001,
                               "at \(width) pt the shelf's content reports its own width: \(scroll)",
                               file: file, line: line)
            }
        }
        XCTAssertGreaterThan(checked, 0, "no window had room between its insets, so nothing was tested",
                             file: file, line: line)
    }

    /// A returning player's shelf: the Continue hero over the grid, which is
    /// the content that hung the launch.
    func testTheShelfWithAContinueHeroIsAsWideAsItsWindow() throws {
        try assertHeldToTheWindow(continueHero: true)
    }

    /// The open iPhone Duo held wide (951 pt), then narrowed to the 491 pt
    /// the shelf has beside the Settings panel's column there. Held to its
    /// container instead of its offer, the shelf's scroll view stayed wider
    /// than that and was cut at its left on every launch (issue #469); here
    /// it stayed 951 pt wide at x -230.
    func testTheShelfNarrowsWithItsWindow() throws {
        try assertHeldToTheWindow(continueHero: false, widths: [491], laidOutFirstAt: 951)
        try assertHeldToTheWindow(continueHero: true, widths: [491], laidOutFirstAt: 951)
    }

    /// A first launch: the welcome card over the grid. On an iPhone 18 Pro
    /// this content only overflows the 60 pt window, so it is the case
    /// above that fails at every width when the modifier goes.
    func testTheFirstLaunchShelfIsAsWideAsItsWindow() throws {
        try assertHeldToTheWindow(continueHero: false)
    }
}
