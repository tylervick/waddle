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

    // MARK: Hotspot disc (ring only; the grid keeps its rectangle)

    func testHotspotDiscContainsTheCentre() {
        for g in [classic, wide, small] {
            XCTAssertTrue(g.isInHotspot(g.center), "\(g.pictureRect)")
        }
    }

    func testHotspotDiscReachesNearlyToTheInnerEdge() {
        let r = classic.innerRadius
        XCTAssertTrue(classic.isInHotspot(point(classic, degrees: 135, distance: 0.9 * r)), "0.9 r up-left")
        XCTAssertFalse(classic.isInHotspot(point(classic, degrees: 135, distance: 1.1 * r)), "1.1 r up-left")
        XCTAssertTrue(classic.isInHotspot(point(classic, degrees: -90, distance: 0.9 * r)),
                      "it covers the status-bar strip under the centre")
    }

    /// The hotspot view's frame is only the disc's bounding box: its corners
    /// are not the hotspot.
    func testLocateUsesTheDiscNotItsBoundingBox() {
        let r = classic.innerRadius
        let corner = CGPoint(x: classic.center.x - 0.9 * r, y: classic.center.y + 0.9 * r)
        XCTAssertTrue(classic.hotspot.contains(corner))
        XCTAssertFalse(classic.isInHotspot(corner))
        XCTAssertFalse(classic.locate(corner).inHotspot)
        XCTAssertTrue(classic.locate(classic.center).inHotspot)
    }

    /// On a widescreen picture the disc reaches past the picture's bottom
    /// edge (r = 74.3, the centre is 64.3 above it); that part is clipped.
    func testHotspotDiscIsClippedToThePicture() {
        let below = CGPoint(x: wide.center.x, y: wide.pictureRect.maxY + 1)
        XCTAssertLessThan(below.y - wide.center.y, wide.innerRadius)
        XCTAssertFalse(wide.isInHotspot(below))
        XCTAssertEqual(wide.hotspot.maxY, wide.pictureRect.maxY, accuracy: 1e-9)
        XCTAssertEqual(wide.hotspot.minY, wide.center.y - wide.innerRadius, accuracy: 1e-9)
        XCTAssertEqual(wide.hotspot.width, 2 * wide.innerRadius, accuracy: 1e-9)
    }

    /// The hotspot view's frame is the disc's bounding box clipped to the
    /// picture. Its centre, which UI tests tap, is in the disc and in no
    /// wedge, strict or generous, on every picture here and on a portrait
    /// 402-wide phone at 4:3 and 16:10.
    func testHotspotFrameCentreIsInTheDiscAndNoWedge() {
        let portrait43 = WeaponRingGeometry(pictureRect: CGRect(x: 0, y: 286.25, width: 402, height: 301.5))
        let portrait1610 = WeaponRingGeometry(pictureRect: CGRect(x: 0, y: 311.5, width: 402, height: 251.25))
        for g in [classic, wide, small, portrait43, portrait1610] {
            let c = CGPoint(x: g.hotspot.midX, y: g.hotspot.midY)
            XCTAssertTrue(g.isInHotspot(c), "\(g.pictureRect)")
            XCTAssertNil(g.drawnWedge(at: c), "\(g.pictureRect)")
            XCTAssertNil(g.wedge(at: c), "\(g.pictureRect)")
        }
    }

    func testHotspotAndDrawnWedgesDoNotOverlap() {
        let r = classic.innerRadius
        for degrees in stride(from: CGFloat(1), to: 180, by: 7) {
            let inside = point(classic, degrees: degrees, distance: r - 0.01)
            let outside = point(classic, degrees: degrees, distance: r + 0.01)
            XCTAssertTrue(classic.isInHotspot(inside))
            XCTAssertNil(classic.drawnWedge(at: inside))
            XCTAssertFalse(classic.isInHotspot(outside))
            XCTAssertNotNil(classic.drawnWedge(at: outside))
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
        // The generous band reaches into the hotspot disc (0.75 r to r).
        let inHole = classic.locate(point(classic, degrees: 90, distance: 0.9 * classic.innerRadius))
        XCTAssertTrue(inHole.inHotspot)
        XCTAssertEqual(inHole.wedge, 3)
        XCTAssertNil(inHole.drawnWedge)
    }

    // MARK: Strict band (touch-downs) against the generous band (a tracked slide)

    func testATouchDownJustOutsideTheDrawingIsOnNoDrawnWedge() {
        let R = classic.outerRadius, r = classic.innerRadius
        let past = point(classic, degrees: 30, distance: 1.2 * R)
        XCTAssertNil(classic.drawnWedge(at: past), "1.2 R: past the outer edge")
        XCTAssertEqual(classic.wedge(at: past), 5, "a tracked slide may still overshoot there")
        XCTAssertEqual(classic.locate(past), WeaponRingPoint(wedge: 5, inHotspot: false, onDrawing: false))

        let under = point(classic, degrees: 150, distance: 0.85 * r)
        XCTAssertNil(classic.drawnWedge(at: under), "0.85 r: under the inner edge")
        XCTAssertEqual(classic.wedge(at: under), 1)
        XCTAssertNil(classic.locate(under).drawnWedge)
    }

    func testDrawnBandEdges() {
        let R = classic.outerRadius, r = classic.innerRadius
        XCTAssertEqual(classic.drawnWedge(at: point(classic, degrees: 90, distance: R + 1)), 3, "within the slack")
        XCTAssertNil(classic.drawnWedge(at: point(classic, degrees: 90, distance: R + 3)))
        XCTAssertEqual(classic.drawnWedge(at: point(classic, degrees: 90, distance: r + 0.5)), 3)
        XCTAssertNil(classic.drawnWedge(at: point(classic, degrees: 90, distance: r - 0.01)), "inside r is the hotspot's")
        XCTAssertNil(classic.drawnWedge(at: point(classic, degrees: -45, distance: (R + r) / 2)), "below the line")
        for i in 0..<7 {
            XCTAssertEqual(classic.drawnWedge(at: classic.wedgeMidpoint(i)), i)
        }
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
