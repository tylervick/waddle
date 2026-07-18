import XCTest
@testable import BoomBox

final class TouchStickModelTests: XCTestCase {
    let stick = TouchStickModel(center: CGPoint(x: 100, y: 100), radius: 50)

    func testCenterIsNeutral() {
        let axes = stick.axes(for: CGPoint(x: 100, y: 100))
        XCTAssertEqual(axes.x, 0)
        XCTAssertEqual(axes.y, 0)
    }

    func testInsideDeadZoneIsNeutral() {
        // deadZone 0.2 * radius 50 = 10 points; 8 points right is inside
        let axes = stick.axes(for: CGPoint(x: 108, y: 100))
        XCTAssertEqual(axes.x, 0)
        XCTAssertEqual(axes.y, 0)
    }

    func testFullDeflectionRightClampsToOne() {
        let axes = stick.axes(for: CGPoint(x: 300, y: 100))
        XCTAssertEqual(axes.x, 1.0, accuracy: 0.001)
        XCTAssertEqual(axes.y, 0.0, accuracy: 0.001)
    }

    func testDownIsPositiveY() {
        let axes = stick.axes(for: CGPoint(x: 100, y: 200))
        XCTAssertEqual(axes.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(axes.y, 1.0, accuracy: 0.001)
    }

    func testMidwayRescalesLinearly() {
        // 30 points right: (30-10)/(50-10) = 0.5
        let axes = stick.axes(for: CGPoint(x: 130, y: 100))
        XCTAssertEqual(axes.x, 0.5, accuracy: 0.001)
    }

    func testDiagonalStaysInsideUnitCircle() {
        let axes = stick.axes(for: CGPoint(x: 200, y: 200))
        let magnitude = sqrt(Double(axes.x * axes.x + axes.y * axes.y))
        XCTAssertEqual(magnitude, 1.0, accuracy: 0.001)
    }

    func testKnobPositionClampsToRadius() {
        let knob = stick.knobPosition(for: CGPoint(x: 300, y: 100))
        XCTAssertEqual(knob.x, 150, accuracy: 0.001)  // center.x + radius
        XCTAssertEqual(knob.y, 100, accuracy: 0.001)
    }

    func testKnobPositionInsideRadiusFollowsTouch() {
        let knob = stick.knobPosition(for: CGPoint(x: 120, y: 110))
        XCTAssertEqual(knob.x, 120, accuracy: 0.001)
        XCTAssertEqual(knob.y, 110, accuracy: 0.001)
    }
}
