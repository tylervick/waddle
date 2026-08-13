import UIKit
import XCTest
@testable import WADdle

/// `OverlayButton` draws itself as a circle (`layer.cornerRadius = size / 2`)
/// but is a plain square `UIView`, so UIKit's default rectangular hit-testing
/// used to accept every point in the frame -- including the four corners,
/// which are visually off the control. These pin the hit area to the drawn
/// circle: a corner touch is not delivered to the button at all
/// (`hitTest` returns nil, so `touchesBegan`/`touchesEnded` never fire), the
/// same way it would not be for a genuinely circular control.
///
/// The UITest counterpart (`TouchControlsTests.testCornerTapMissesCircularButton`)
/// proves the same thing end to end with a real synthesized tap; this one pins
/// the geometry directly and runs in the unit suite CI executes.
@MainActor
final class OverlayButtonHitAreaTests: XCTestCase {
    private let size: CGFloat = 84

    private func makeButton(onPress: @escaping (Bool) -> Void = { _ in }) -> OverlayButton {
        OverlayButton(title: "FIRE", size: size, onPress: onPress)
    }

    func testCornerInsideFrameButOutsideCircleIsNotHit() {
        let button = makeButton()
        // Well inside the square frame (6.7pt from each edge) and well
        // outside the circle: 49.9pt from centre against a 42pt radius.
        let corner = CGPoint(x: size * 0.08, y: size * 0.08)
        XCTAssertTrue(button.frame.contains(corner), "test point left the square frame")
        XCTAssertNil(button.hitTest(corner, with: nil),
                     "corner touch was still delivered to the button")
    }

    func testEveryCornerOfTheFrameMisses() {
        let button = makeButton()
        for offset in [CGPoint(x: 0.08, y: 0.08), CGPoint(x: 0.92, y: 0.08),
                       CGPoint(x: 0.08, y: 0.92), CGPoint(x: 0.92, y: 0.92)] {
            let point = CGPoint(x: size * offset.x, y: size * offset.y)
            XCTAssertNil(button.hitTest(point, with: nil),
                         "corner \(offset) was still delivered to the button")
        }
    }

    func testCentreIsHit() {
        let button = makeButton()
        XCTAssertTrue(button.hitTest(CGPoint(x: size / 2, y: size / 2), with: nil) === button,
                      "centre touch no longer reaches the button")
    }

    /// The full circle stays live, not just the middle: a point just inside
    /// the rim must still hit, so the fix cannot be satisfied by shrinking
    /// the control instead of rounding it.
    func testJustInsideTheRimIsHit() {
        let radius = size / 2
        let button = makeButton()
        for angle in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 4) {
            let point = CGPoint(x: radius + CGFloat(cos(angle)) * (radius - 1),
                                y: radius + CGFloat(sin(angle)) * (radius - 1))
            XCTAssertTrue(button.hitTest(point, with: nil) === button,
                          "point just inside the rim at \(angle) rad no longer hits")
        }
    }

    func testJustOutsideTheRimMisses() {
        let radius = size / 2
        let button = makeButton()
        // 45 degrees: the only direction where a point beyond the rim is
        // still inside the square frame, i.e. exactly the corner gap.
        let point = CGPoint(x: radius + CGFloat(cos(Double.pi / 4)) * (radius + 1),
                            y: radius + CGFloat(sin(Double.pi / 4)) * (radius + 1))
        XCTAssertTrue(button.frame.contains(point), "test point left the square frame")
        XCTAssertNil(button.hitTest(point, with: nil),
                     "point just outside the rim was still delivered to the button")
    }

    /// The visual and the hit area are derived from the same `size`, so a
    /// differently-sized button must round to its own radius rather than a
    /// hardcoded one.
    func testSmallerButtonRoundsToItsOwnRadius() {
        let small = OverlayButton(title: "MAP", size: 48) { _ in }
        XCTAssertNil(small.hitTest(CGPoint(x: 4, y: 4), with: nil))
        XCTAssertTrue(small.hitTest(CGPoint(x: 24, y: 24), with: nil) === small)
    }
}
