import CoreGraphics

/// Where a touch is, as the ring's rules need it: the wedge under it (with
/// the generous hit band) and, independently, whether it is in the hotspot.
/// The hotspot's top corners reach above the ring's centre into the band, so
/// a point can be both.
struct WeaponRingPoint: Equatable {
    var wedge: Int?
    var inHotspot: Bool
}

/// Where the weapon-select ring sits over the game picture. Pure, like
/// `WeaponSelectGeometry`, so `WaddleTests` pins the layout without UIKit.
///
/// Every value is a fraction of the picture rect `P`, not of the screen. The
/// centre is on the top edge of the status bar (32 of the picture's 200
/// rows); seven equal wedges fan across the upper half-circle, slot 0 at the
/// left horizon and slot 6 at the right. The hotspot is the grid's.
struct WeaponRingGeometry: Equatable {
    static let wedgeCount = WeaponRingSlots.count

    let pictureRect: CGRect
    let center: CGPoint
    let outerRadius: CGFloat
    let innerRadius: CGFloat
    let hotspot: CGRect

    init(pictureRect p: CGRect) {
        pictureRect = p
        center = CGPoint(x: p.midX, y: p.maxY - 32.0 / 200 * p.height)
        outerRadius = min(0.24 * p.width, 0.55 * 168.0 / 200 * p.height)
        innerRadius = 0.40 * outerRadius
        hotspot = WeaponSelectGeometry(pictureRect: p).hotspot
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

    /// The wedge under `point`, or nil. More generous than the drawing so a
    /// slide can overshoot: above the centre line, and between 0.75 · r and
    /// 1.35 · R from the centre.
    func wedge(at point: CGPoint) -> Int? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        guard dy < 0 else { return nil }
        let d = (dx * dx + dy * dy).squareRoot()
        guard d >= 0.75 * innerRadius, d <= 1.35 * outerRadius else { return nil }
        // atan2 is in (-pi, 0) above the centre; shift into (pi, 2·pi).
        let angle = atan2(dy, dx) + 2 * .pi
        let index = Int(((angle - .pi) / Self.sweep).rounded(.down))
        return min(max(index, 0), Self.wedgeCount - 1)
    }

    func locate(_ point: CGPoint) -> WeaponRingPoint {
        WeaponRingPoint(wedge: wedge(at: point), inHotspot: hotspot.contains(point))
    }
}
