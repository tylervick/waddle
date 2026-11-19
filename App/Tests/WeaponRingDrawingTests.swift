import CoreGraphics
import XCTest
@testable import Waddle

/// The ring's drawing arithmetic: where a sprite goes inside its wedge's
/// panel. `WeaponRingViewTests` pins that the view uses it.
final class WeaponRingDrawingTests: XCTestCase {
    private let geometry = WeaponRingGeometry(pictureRect: CGRect(x: 30, y: 10, width: 720, height: 480))

    /// Wedge `i`'s panel as the view draws it, in the geometry's coordinates.
    private func panel(_ i: Int) -> CGPath {
        let angles = geometry.wedgeAngles(i)
        return WeaponRingDrawing.panelPath(center: geometry.center, inner: geometry.innerRadius,
                                           outer: geometry.outerRadius, start: angles.start, end: angles.end,
                                           gap: max(1, (geometry.outerRadius * 0.02).rounded()))
    }

    private func fit(_ size: CGSize, in i: Int) -> CGRect {
        WeaponRingDrawing.fittedSpriteRect(imageSize: size, center: geometry.wedgeMidpoint(i),
                                           side: geometry.spriteSide, floorY: geometry.center.y,
                                           panel: panel(i))
    }

    /// Wide, square and tall sprites in the end wedges and the top one: the
    /// fitted rectangle keeps the sprite's aspect, its four corners are on
    /// the panel, and it is not degenerate (long side at least 0.15 · R).
    func testFittedSpritesLieInsideTheirPanels() {
        let R = geometry.outerRadius
        for i in [0, 3, 6] {
            let path = panel(i)
            for size in [CGSize(width: 2, height: 1), CGSize(width: 1, height: 1), CGSize(width: 1, height: 2)] {
                let rect = fit(size, in: i)
                let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                               CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
                for c in corners { XCTAssertTrue(path.contains(c), "wedge \(i) \(size) corner \(c)") }
                XCTAssertGreaterThanOrEqual(max(rect.width, rect.height), 0.15 * R, "wedge \(i) \(size)")
                XCTAssertEqual(rect.width / rect.height, size.width / size.height, accuracy: 1e-6)
            }
        }
    }

    /// Every wedge, every sampled edge point, not just the corners: the inner
    /// arc is concave, so corners alone could let an edge dip under it.
    func testEveryWedgesFitKeepsItsEdgesOnThePanel() {
        for i in 0..<7 {
            let path = panel(i)
            for size in [CGSize(width: 3, height: 1), CGSize(width: 1, height: 1), CGSize(width: 1, height: 3)] {
                let rect = fit(size, in: i)
                XCTAssertFalse(rect.isEmpty)
                // Sampled here, densely, not with `edgePoints`, so the test does
                // not trust the sampling it checks.
                let steps = (0...20).map { CGFloat($0) / 20 }
                let edges = steps.flatMap { t in
                    [CGPoint(x: rect.minX + t * rect.width, y: rect.minY),
                     CGPoint(x: rect.minX + t * rect.width, y: rect.maxY),
                     CGPoint(x: rect.minX, y: rect.minY + t * rect.height),
                     CGPoint(x: rect.maxX, y: rect.minY + t * rect.height)]
                }
                XCTAssertTrue(edges.allSatisfy { path.contains($0) }, "wedge \(i) \(size)")
            }
        }
    }

    /// A wide sprite in the top wedge shrinks, centred, rather than being
    /// cut: the square fit (0.48 · R wide) is wider than the panel there.
    func testAWideSpriteShrinksToTheTopWedgesWidth() {
        let rect = fit(CGSize(width: 2, height: 1), in: 3)
        XCTAssertLessThan(rect.width, geometry.spriteSide)
        XCTAssertEqual(rect.midX, geometry.wedgeMidpoint(3).x, accuracy: 1e-6)
        XCTAssertEqual(rect.midY, geometry.wedgeMidpoint(3).y, accuracy: 1e-6)
    }

    /// The largest that fits: one 5 % step larger would not.
    func testTheFitIsNotSmallerThanItNeedsToBe() {
        for i in [0, 3, 6] {
            let rect = fit(CGSize(width: 2, height: 1), in: i)
            guard rect.width < geometry.spriteSide else { continue }
            let grown = rect.insetBy(dx: -rect.width * 0.05 / 0.95 / 2, dy: -rect.height * 0.05 / 0.95 / 2)
            XCTAssertFalse(WeaponRingDrawing.edgePoints(of: grown).allSatisfy { panel(i).contains($0) },
                           "wedge \(i): one step larger should leave the panel")
        }
    }

    func testAnEmptyImageFitsNowhere() {
        XCTAssertEqual(fit(.zero, in: 3), .zero)
    }
}
