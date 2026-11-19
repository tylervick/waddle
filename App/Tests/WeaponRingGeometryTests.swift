import CoreGraphics
import XCTest
@testable import Waddle

/// Where the ring sits over the game picture and which wedge a point is in.
/// Every value is a fraction of the picture rect `P`.
final class WeaponRingGeometryTests: XCTestCase {
    /// 3:2, width-limited: R = 0.24 · 720 = 172.8 (the height bound is 221.76).
    private let classic = WeaponRingGeometry(pictureRect: CGRect(x: 30, y: 10, width: 720, height: 480))
    /// Widescreen, height-limited: R = 0.55 · 168/200 · 402 = 185.724.
    private let wide = WeaponRingGeometry(pictureRect: CGRect(x: 0, y: 0, width: 874, height: 402))
    /// A small 320x200 picture.
    private let small = WeaponRingGeometry(pictureRect: CGRect(x: 0, y: 0, width: 320, height: 200))

    /// The point at `distance` from the centre, `degrees` anticlockwise from
    /// the right horizon (90 is straight up), in UIKit's y-down coordinates.
    private func point(_ g: WeaponRingGeometry, degrees: CGFloat, distance: CGFloat) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: g.center.x + distance * cos(a), y: g.center.y - distance * sin(a))
    }

    func testCentreSitsOnTheStatusBarsTopEdge() {
        XCTAssertEqual(classic.center.x, 390, accuracy: 1e-9)
        XCTAssertEqual(classic.center.y, 490 - 32.0 / 200 * 480, accuracy: 1e-9)
        XCTAssertEqual(wide.center.x, 437, accuracy: 1e-9)
        XCTAssertEqual(wide.center.y, 402 - 32.0 / 200 * 402, accuracy: 1e-9)
    }

    func testRadiiOnAClassicPictureFollowTheWidth() {
        XCTAssertEqual(classic.outerRadius, 0.24 * 720, accuracy: 1e-9)
        XCTAssertEqual(classic.innerRadius, 0.40 * 0.24 * 720, accuracy: 1e-9)
    }

    func testRadiiOnAWidescreenPictureFollowTheHeight() {
        XCTAssertEqual(wide.outerRadius, 0.55 * 168 / 200 * 402, accuracy: 1e-9)
        XCTAssertEqual(wide.innerRadius, 0.40 * 0.55 * 168 / 200 * 402, accuracy: 1e-9)
    }

    func testSmallPicture() {
        XCTAssertEqual(small.center, CGPoint(x: 160, y: 168))
        XCTAssertEqual(small.outerRadius, 0.24 * 320, accuracy: 1e-9)
        XCTAssertEqual(small.wedge(at: small.wedgeMidpoint(3)), 3)
    }

    func testHotspotIsTheGrids() {
        for g in [classic, wide, small] {
            XCTAssertEqual(g.hotspot, WeaponSelectGeometry(pictureRect: g.pictureRect).hotspot)
        }
    }

    func testSevenEqualWedgesAcrossTheUpperHalf() {
        XCTAssertEqual(WeaponRingGeometry.wedgeCount, 7)
        let sweep = CGFloat.pi / 7
        for i in 0..<7 {
            let a = classic.wedgeAngles(i)
            XCTAssertEqual(a.start, .pi + CGFloat(i) * sweep, accuracy: 1e-9, "wedge \(i)")
            XCTAssertEqual(a.end, .pi + CGFloat(i + 1) * sweep, accuracy: 1e-9, "wedge \(i)")
        }
    }

    func testSlotZeroIsAtTheLeftHorizonAndSixAtTheRight() {
        let mid = (classic.outerRadius + classic.innerRadius) / 2
        XCTAssertEqual(classic.wedge(at: point(classic, degrees: 179, distance: mid)), 0)
        XCTAssertEqual(classic.wedge(at: point(classic, degrees: 90, distance: mid)), 3)
        XCTAssertEqual(classic.wedge(at: point(classic, degrees: 1, distance: mid)), 6)
    }

    func testEveryWedgeMidpointIsInItsWedge() {
        for g in [classic, wide, small] {
            for i in 0..<7 {
                XCTAssertEqual(g.wedge(at: g.wedgeMidpoint(i)), i, "wedge \(i) of \(g.pictureRect)")
                let p = g.wedgeMidpoint(i)
                XCTAssertEqual(hypot(p.x - g.center.x, p.y - g.center.y),
                               (g.outerRadius + g.innerRadius) / 2, accuracy: 1e-9)
            }
        }
    }

    func testWedgeBoundaries() {
        let mid = (classic.outerRadius + classic.innerRadius) / 2
        let step: CGFloat = 180.0 / 7
        for i in 0..<7 {
            // Wedge i runs from 180 - i·step down to 180 - (i+1)·step degrees.
            let left = 180 - CGFloat(i) * step - 0.5
            let right = 180 - CGFloat(i + 1) * step + 0.5
            XCTAssertEqual(classic.wedge(at: point(classic, degrees: left, distance: mid)), i)
            XCTAssertEqual(classic.wedge(at: point(classic, degrees: right, distance: mid)), i)
        }
    }

    /// Hit-testing reaches past the drawing so a slide can overshoot:
    /// 0.75 · r to 1.35 · R from the centre.
    func testOvershootBand() {
        let R = classic.outerRadius, r = classic.innerRadius
        XCTAssertEqual(classic.wedge(at: point(classic, degrees: 90, distance: 1.34 * R)), 3)
        XCTAssertNil(classic.wedge(at: point(classic, degrees: 90, distance: 1.36 * R)))
        XCTAssertEqual(classic.wedge(at: point(classic, degrees: 90, distance: 0.76 * r)), 3)
        XCTAssertNil(classic.wedge(at: point(classic, degrees: 90, distance: 0.74 * r)))
        XCTAssertEqual(classic.wedge(at: point(classic, degrees: 170, distance: 1.2 * R)), 0,
                       "beyond the drawn outer edge still counts")
        XCTAssertEqual(classic.wedge(at: point(classic, degrees: 10, distance: 0.9 * r)), 6,
                       "inside the drawn inner edge still counts")
    }

    func testBelowTheCentreLineIsNoWedge() {
        let mid = (classic.outerRadius + classic.innerRadius) / 2
        XCTAssertNil(classic.wedge(at: point(classic, degrees: -1, distance: mid)))
        XCTAssertNil(classic.wedge(at: point(classic, degrees: -90, distance: mid)))
        XCTAssertNil(classic.wedge(at: point(classic, degrees: 181, distance: mid)))
        XCTAssertNil(classic.wedge(at: CGPoint(x: classic.center.x - mid, y: classic.center.y)),
                     "on the centre line is not above it")
    }

    func testHotspotCentreIsBelowTheRing() {
        for g in [classic, wide, small] {
            let p = CGPoint(x: g.hotspot.midX, y: g.hotspot.midY)
            XCTAssertNil(g.wedge(at: p), "a tap in the middle of the hotspot is not over a wedge")
            XCTAssertEqual(g.locate(p), WeaponRingPoint(wedge: nil, inHotspot: true))
        }
    }

    func testLocateReportsWedgeAndHotspotIndependently() {
        XCTAssertEqual(classic.locate(classic.wedgeMidpoint(1)), WeaponRingPoint(wedge: 1, inHotspot: false))
        XCTAssertEqual(classic.locate(CGPoint(x: 31, y: 11)), WeaponRingPoint(wedge: nil, inHotspot: false))
        // The hotspot's top corners reach above the centre line into the band.
        let corner = CGPoint(x: classic.hotspot.maxX - 1, y: classic.hotspot.minY + 1)
        let located = classic.locate(corner)
        XCTAssertTrue(located.inHotspot)
        XCTAssertNotNil(located.wedge)
    }

    func testSpriteSide() {
        XCTAssertEqual(classic.spriteSide, 0.8 * (classic.outerRadius - classic.innerRadius), accuracy: 1e-9)
    }

    func testEmptyPictureHasNoWedges() {
        let g = WeaponRingGeometry(pictureRect: .zero)
        XCTAssertNil(g.wedge(at: .zero))
        XCTAssertNil(g.wedge(at: CGPoint(x: 0, y: -1)))
    }
}
