import SwiftUI
import XCTest
@testable import Waddle

/// The real shelf holds its content to its container's width (issues #437
/// and #450).
///
/// `ScrollContentWidthTests` shows what `reportingContainerWidth()` does, on
/// a scroll view of its own. This hosts `ShelfView` itself, so that taking
/// the modifier off its scroll content, or moving it to another view, fails
/// here and not on an open iPhone Duo at the largest text size.
///
/// The shelf is put in a window too narrow for what it holds. Its content
/// then reports wider than it is offered, by a lot and without a loop, and a
/// scroll view follows that: with the modifier deleted, the scroll view in a
/// 120 pt window was 269 pt wide (iPhone 18 Pro simulator, iOS 27.0,
/// 2026-11-21; the same with the modifier moved onto the `ScrollView`). With
/// the modifier where it belongs, the scroll view and its content are the
/// window's width at every size below.
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

    /// The frame, in the window, and the content size of each scroll view
    /// the hosted shelf made.
    private func shelfScrollViews(continueHero: Bool, width: CGFloat) throws
        -> [(frame: CGRect, contentSize: CGSize)] {
        let fixture = continueHero ? ShelfPreviewFixture.continueHero() : ShelfPreviewFixture.factory()
        if continueHero, let played = try fixture.library.recentlyPlayed(limit: 1).first {
            seededGameIDs.append(played.id)
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: Self.height))
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ShelfView(library: fixture.library, importer: fixture.importer,
                      lastExitCode: .constant(nil), panelModel: ShelfPanelModel())
        }.dynamicTypeSize(.accessibility5))
        window.isHidden = false
        // Several turns: the shelf loads its games on appearing, and sizes
        // its hero a layout pass after it is measured.
        for _ in 0..<20 {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let found = scrollViews(in: window).map {
            (frame: $0.convert($0.bounds, to: window), contentSize: $0.contentSize)
        }
        window.isHidden = true
        window.rootViewController = nil
        return found
    }

    private func assertHeldToTheWindow(continueHero: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        for width in Self.widths {
            let scrolls = try shelfScrollViews(continueHero: continueHero, width: width)
            XCTAssertEqual(scrolls.count, 1, "the shelf is one scroll view; found \(scrolls) at \(width) pt",
                           file: file, line: line)
            for scroll in scrolls {
                XCTAssertEqual(scroll.frame.minX, 0, accuracy: 0.0001,
                               "at \(width) pt the shelf's scroll view is \(scroll.frame)", file: file, line: line)
                XCTAssertEqual(scroll.frame.width, width, accuracy: 0.0001,
                               "at \(width) pt the shelf's scroll view followed its content: \(scroll.frame)",
                               file: file, line: line)
                XCTAssertEqual(scroll.contentSize.width, width, accuracy: 0.0001,
                               "at \(width) pt the shelf's content reports its own width: \(scroll.contentSize)",
                               file: file, line: line)
            }
        }
    }

    /// A returning player's shelf: the Continue hero over the grid, which is
    /// the content that hung the launch.
    func testTheShelfWithAContinueHeroIsAsWideAsItsWindow() throws {
        try assertHeldToTheWindow(continueHero: true)
    }

    /// A first launch: the welcome card over the grid.
    func testTheFirstLaunchShelfIsAsWideAsItsWindow() throws {
        try assertHeldToTheWindow(continueHero: false)
    }
}
