import UIKit
import XCTest
@testable import Waddle

/// The drag-and-drop editor's canvas (issue #115), driven through the same
/// begin/continue/end entry points its touch handlers call, with no UITouch:
/// a drag that starts on a button moves that button and reports the new
/// offsets; a drag that starts on empty space moves nothing; the frames it
/// shows are exactly `TouchOverlayLayout`'s for the same bounds and
/// overrides, so the editor cannot show one arrangement and the session
/// install another.
@MainActor
final class TouchLayoutEditorCanvasTests: XCTestCase {
    private static let phoneLandscape = CGRect(x: 0, y: 0, width: 874, height: 402)

    private func canvas(overrides: TouchOverlayLayoutOverrides = .none) -> TouchLayoutEditorCanvas {
        let view = TouchLayoutEditorCanvas(overrides: overrides)
        view.frame = Self.phoneLandscape
        view.layoutIfNeeded()
        return view
    }

    private func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    /// The editor shows the session's geometry, not its own.
    func testButtonsSitWhereTheLayoutPutsThem() {
        var overrides = TouchOverlayLayoutOverrides.none
        overrides[.use] = CGPoint(x: -80, y: -40)
        let view = canvas(overrides: overrides)
        let expected = TouchOverlayLayout(bounds: Self.phoneLandscape, safeAreaInsets: .zero,
                                          hudReserve: 0, overrides: overrides)
        for control in TouchOverlayControl.allCases {
            XCTAssertEqual(view.frame(for: control), expected.frame(for: control), control.rawValue)
        }
    }

    /// Grab FIRE off-center, drag it, and the button follows the finger with
    /// the grab point kept (no jump to the finger on the first move); the
    /// stored offset is the clamped one for where it ended up; the change is
    /// reported once per move so a host can keep its copy current.
    func testDraggingAButtonMovesItAndReportsTheOffsets() {
        let view = canvas()
        var reported: [TouchOverlayLayoutOverrides] = []
        view.onChange = { reported.append($0) }

        let start = view.frame(for: .fire)
        let grab = CGPoint(x: start.midX + 10, y: start.midY - 8) // inside the circle, off-center
        XCTAssertTrue(view.beginDrag(at: grab), "a touch inside FIRE should start a drag")

        view.continueDrag(to: CGPoint(x: grab.x - 200, y: grab.y - 100))
        view.layoutIfNeeded()
        let moved = view.frame(for: .fire)
        XCTAssertEqual(moved.midX, start.midX - 200, accuracy: 0.001)
        XCTAssertEqual(moved.midY, start.midY - 100, accuracy: 0.001)
        XCTAssertEqual(moved.size, start.size)
        view.endDrag()

        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(view.overrides[.fire]?.x ?? .nan, -200, accuracy: 0.001)
        XCTAssertEqual(view.overrides[.fire]?.y ?? .nan, -100, accuracy: 0.001)
        for control in TouchOverlayControl.allCases where control != .fire {
            XCTAssertNil(view.overrides[control], "\(control.rawValue) moved without being dragged")
        }
    }

    /// Dragging past the edge parks the button at the edge and stores that,
    /// so the persisted layout is the one the player saw, not the finger's
    /// off-screen position.
    func testDraggingPastTheEdgeStoresTheClampedPosition() {
        let view = canvas()
        let start = view.frame(for: .menu)
        XCTAssertTrue(view.beginDrag(at: center(start)))
        view.continueDrag(to: CGPoint(x: 5000, y: -5000))
        view.layoutIfNeeded()
        view.endDrag()
        let parked = view.frame(for: .menu)
        XCTAssertTrue(Self.phoneLandscape.contains(parked), "\(parked)")
        XCTAssertEqual(parked.maxX, Self.phoneLandscape.maxX, accuracy: 0.001)
        XCTAssertEqual(parked.minY, 0, accuracy: 0.001)
        // And the stored offset reproduces exactly that frame on a fresh layout.
        let fresh = TouchOverlayLayout(bounds: Self.phoneLandscape, safeAreaInsets: .zero,
                                       hudReserve: 0, overrides: view.overrides)
        XCTAssertEqual(fresh.frame(for: .menu), parked)
    }

    /// Empty space starts nothing: the canvas has no stick to draw and no
    /// turn to track, so a miss is a miss.
    func testDragFromEmptySpaceMovesNothing() {
        let view = canvas()
        var reported = 0
        view.onChange = { _ in reported += 1 }
        let before = TouchOverlayControl.allCases.map { view.frame(for: $0) }
        XCTAssertFalse(view.beginDrag(at: CGPoint(x: 437, y: 150)), "the middle of the screen is not a button")
        view.continueDrag(to: CGPoint(x: 100, y: 100))
        view.endDrag()
        view.layoutIfNeeded()
        XCTAssertEqual(TouchOverlayControl.allCases.map { view.frame(for: $0) }, before)
        XCTAssertEqual(reported, 0)
        XCTAssertTrue(view.overrides.isEmpty)
    }

    /// A touch in the square corner outside the drawn circle is a miss, the
    /// same inscribed-circle rule `OverlayButton.point(inside:)` applies in
    /// the session.
    func testCornerOfTheSquareFrameIsNotTheButton() {
        let view = canvas()
        let fire = view.frame(for: .fire)
        XCTAssertFalse(view.beginDrag(at: CGPoint(x: fire.minX + 1, y: fire.minY + 1)))
    }

    /// Setting the overrides from outside (Reset) relays out immediately,
    /// so the editor shows the defaults the moment Reset is tapped.
    func testSettingOverridesRelaysOut() {
        var overrides = TouchOverlayLayoutOverrides.none
        overrides[.fire] = CGPoint(x: -300, y: -100)
        let view = canvas(overrides: overrides)
        let moved = view.frame(for: .fire)
        view.overrides = .none
        view.layoutIfNeeded()
        let reset = view.frame(for: .fire)
        XCTAssertNotEqual(moved, reset)
        XCTAssertEqual(reset, TouchOverlayLayout(bounds: Self.phoneLandscape, safeAreaInsets: .zero,
                                                 hudReserve: 0).frame(for: .fire))
    }

    /// The editor's buttons are addressable by UI tests under their own
    /// identifiers, distinct from the in-session overlay's, so a test can
    /// never confuse the two.
    func testEditorButtonsCarryEditorIdentifiers() {
        let view = canvas()
        let ids = Set(view.subviews.compactMap(\.accessibilityIdentifier))
        for control in TouchOverlayControl.allCases {
            XCTAssertTrue(ids.contains(TouchLayoutEditorCanvas.identifier(for: control)),
                          "missing editor button for \(control.rawValue)")
            XCTAssertFalse(ids.contains(control.rawValue),
                           "the editor must not reuse the session overlay's identifier \(control.rawValue)")
        }
    }
}
