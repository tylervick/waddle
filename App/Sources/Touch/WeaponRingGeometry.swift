import CoreGraphics

/// Where a touch is, as the ring's rules need it: the wedge under it by the
/// generous band, whether it is also on that wedge's drawn panel (the strict
/// band), and, independently, whether it is in the hotspot. The hotspot (the
/// disc inside the drawn inner edge) and the drawn band do not overlap; the
/// generous band reaches into the disc, so a point can be in the hotspot and
/// over a wedge by the generous test.
///
/// The two bands have different jobs. A touch-down while the ring is open
/// starts tracking only on a drawn wedge (`drawnWedge`): anything off the
/// drawing, a button just outside the outer edge or the strip under the
/// inner edge included, is "anywhere else" and closes. A finger already
/// tracked picks by the generous `wedge`, so a slide may overshoot.
struct WeaponRingPoint: Equatable {
    var wedge: Int?
    var inHotspot: Bool
    /// On the drawn panel of `wedge` (strict band). Required, so a caller
    /// states it: `locate` never reports it true without a wedge, nor
    /// together with `inHotspot`, since the disc and the drawn band do not
    /// overlap.
    var onDrawing: Bool

    /// The wedge whose drawn panel the point is on, or nil.
    var drawnWedge: Int? { onDrawing ? wedge : nil }
}

/// Where the weapon-select ring sits over the game picture. Pure, like
/// `WeaponSelectGeometry`, so `WaddleTests` pins the layout without UIKit.
///
/// Every value is a fraction of the picture rect `P`, not of the screen. The
/// centre is on the top edge of the status bar (32 of the picture's 200
/// rows); seven equal wedges fan across the upper half-circle, slot 0 at the
/// left horizon and slot 6 at the right. The hotspot is the ring's hole: the
/// disc of the drawn inner radius r round the centre, clipped to the
/// picture, so it also covers the status-bar strip under the centre. (The
/// grid keeps its own rectangle, `WeaponSelectGeometry.hotspot`.)
struct WeaponRingGeometry: Equatable {
    static let wedgeCount = WeaponRingSlots.count

    let pictureRect: CGRect
    let center: CGPoint
    let outerRadius: CGFloat
    let innerRadius: CGFloat
    /// The hotspot disc's bounding box clipped to the picture: the frame of
    /// the `weaponSelectHotspot` view. Its centre is in the disc and in no
    /// wedge. Hit-testing uses `isInHotspot(_:)`, not this rectangle.
    let hotspot: CGRect

    init(pictureRect p: CGRect) {
        pictureRect = p
        center = CGPoint(x: p.midX, y: p.maxY - 32.0 / 200 * p.height)
        outerRadius = min(0.24 * p.width, 0.55 * 168.0 / 200 * p.height)
        innerRadius = 0.40 * outerRadius
        let r = innerRadius
        hotspot = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r).intersection(p)
    }

    /// In the hotspot: within r of the centre and inside the picture.
    func isInHotspot(_ point: CGPoint) -> Bool {
        let dx = point.x - center.x
        let dy = point.y - center.y
        return dx * dx + dy * dy <= innerRadius * innerRadius && pictureRect.contains(point)
    }

    private static let sweep = CGFloat.pi / CGFloat(wedgeCount)

    /// Wedge `index`'s angles in UIKit's y-down convention (the one
    /// `UIBezierPath(arcCenter:…)` takes): from pi at the left horizon,
    /// increasing clockwise on screen to 2·pi at the right.
    func wedgeAngles(_ index: Int) -> (start: CGFloat, end: CGFloat) {
        (.pi + CGFloat(index) * Self.sweep, .pi + CGFloat(index + 1) * Self.sweep)
    }

    /// The middle of wedge `index`: mid-angle, mid-radius. Its sprite is
    /// centred here.
    func wedgeMidpoint(_ index: Int) -> CGPoint {
        let a = .pi + (CGFloat(index) + 0.5) * Self.sweep
        let d = (outerRadius + innerRadius) / 2
        return CGPoint(x: center.x + d * cos(a), y: center.y + d * sin(a))
    }

    /// The side of the square a wedge's sprite is fitted into.
    var spriteSide: CGFloat { 0.8 * (outerRadius - innerRadius) }

    /// Points of slack beyond the drawn outer edge in `drawnWedge(at:)`. The
    /// inner edge has none: inside r is the hotspot.
    static let drawnSlack: CGFloat = 2

    /// The wedge under `point` for a finger already tracked, or nil. More
    /// generous than the drawing so a slide can overshoot: above the centre
    /// line, and between 0.75 · r and 1.35 · R from the centre.
    func wedge(at point: CGPoint) -> Int? {
        wedge(at: point, from: 0.75 * innerRadius, to: 1.35 * outerRadius)
    }

    /// The wedge whose drawn panel is under `point`, for a touch-down: above
    /// the centre line, beyond r (the hotspot ends there) and within R plus
    /// `drawnSlack` points.
    func drawnWedge(at point: CGPoint) -> Int? {
        wedge(at: point, from: innerRadius, nearInclusive: false, to: outerRadius + Self.drawnSlack)
    }

    private func wedge(at point: CGPoint, from near: CGFloat, nearInclusive: Bool = true,
                       to far: CGFloat) -> Int? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        guard dy < 0 else { return nil }
        let d = (dx * dx + dy * dy).squareRoot()
        guard nearInclusive ? d >= near : d > near, d <= far else { return nil }
        // atan2 is in (-pi, 0) above the centre; shift into (pi, 2·pi).
        let angle = atan2(dy, dx) + 2 * .pi
        let index = Int(((angle - .pi) / Self.sweep).rounded(.down))
        return min(max(index, 0), Self.wedgeCount - 1)
    }

    func locate(_ point: CGPoint) -> WeaponRingPoint {
        let generous = wedge(at: point)
        return WeaponRingPoint(wedge: generous, inHotspot: isInHotspot(point),
                               onDrawing: generous != nil && drawnWedge(at: point) != nil)
    }
}
