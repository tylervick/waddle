import SwiftUI
import XCTest
@testable import Waddle

/// Issue #496: what `ColumnInsetRepair` acts on, and that it can find what
/// it acts on.
@MainActor
final class ColumnInsetRepairTests: XCTestCase {
    // MARK: The decision

    /// The stray launch, as logged on an open iPhone Duo: no column wanted,
    /// none showing, and the content column still inset by the column's
    /// 364 pt where the window's own inset is 84.
    func testALeftoverColumnInsetIsRepaired() {
        XCTAssertTrue(ColumnInsetRepair.needsRepair(columnIsWanted: false, columnIsShowing: false,
                                                    contentTrailingInset: 364, windowTrailingInset: 84))
    }

    func testAnInsetThatIsTheWindowsOwnIsLeftAlone() {
        XCTAssertFalse(ColumnInsetRepair.needsRepair(columnIsWanted: false, columnIsShowing: false,
                                                     contentTrailingInset: 84, windowTrailingInset: 84))
        XCTAssertFalse(ColumnInsetRepair.needsRepair(columnIsWanted: false, columnIsShowing: false,
                                                     contentTrailingInset: 0, windowTrailingInset: 0))
    }

    /// With a panel open, or a column UIKit is still taking down, the inset
    /// is the column's and is right.
    func testAColumnThatIsWantedOrShowingKeepsItsInset() {
        XCTAssertFalse(ColumnInsetRepair.needsRepair(columnIsWanted: true, columnIsShowing: true,
                                                     contentTrailingInset: 364, windowTrailingInset: 84))
        XCTAssertFalse(ColumnInsetRepair.needsRepair(columnIsWanted: true, columnIsShowing: false,
                                                     contentTrailingInset: 364, windowTrailingInset: 84))
        XCTAssertFalse(ColumnInsetRepair.needsRepair(columnIsWanted: false, columnIsShowing: true,
                                                     contentTrailingInset: 364, windowTrailingInset: 84))
    }

    func testTheColumnIsWantedOnlyWhileOpenOnAWholeLauncher() {
        let model = ShelfPanelModel()
        model.windowWidthChanged(isRegular: true, becameRegular: false)
        XCTAssertFalse(model.columnIsWanted)
        model.panel = .settings
        XCTAssertTrue(model.columnIsWanted)
        model.foldChanged(isSplit: true)
        XCTAssertFalse(model.columnIsWanted, "in two halves the panel is the lower half, not a column")
        model.foldChanged(isSplit: false)
        model.panel = nil
        XCTAssertFalse(model.columnIsWanted)
    }

    // MARK: Finding the column

    /// The repair walks from a view inside the shelf up to the split view
    /// SwiftUI builds `.inspector` on, and asks it for its content column. If
    /// a later SwiftUI builds the inspector some other way, the repair finds
    /// nothing and does nothing, and the stray column of #496 can come back
    /// with nothing else noticing; this fails instead. A regular width is
    /// forced, so it runs on every leg: a compact window makes the inspector
    /// a sheet, with no split view to find.
    func testTheRepairFindsTheInspectorsContentColumn() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let marker = MarkerView()
        let host = UIHostingController(rootView: NavigationStack {
            Color.clear.background { MarkerRepresentable(view: marker) }
        }
        .inspector(isPresented: .constant(false)) { Text("panel") })
        host.traitOverrides.horizontalSizeClass = .regular
        let keyBefore = scene.keyWindow
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            keyBefore?.makeKey()
        }
        let end = Date().addingTimeInterval(1)
        repeat {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        } while Date() < end

        XCTAssertNotNil(marker.window, "the marker never reached the window; the case proves nothing")
        let found = ColumnInsetRepair.contentColumn(containing: marker)
        XCTAssertNotNil(found, "no split view with a content column above the shelf: the repair would do nothing")
    }
}

private final class MarkerView: UIView {}

private struct MarkerRepresentable: UIViewRepresentable {
    let view: MarkerView
    func makeUIView(context: Context) -> MarkerView { view }
    func updateUIView(_ uiView: MarkerView, context: Context) {}
}
