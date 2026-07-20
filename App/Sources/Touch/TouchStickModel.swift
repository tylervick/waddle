import CoreGraphics

/// Pure geometry for a virtual thumbstick. No UIKit, no SDL — fully testable.
struct TouchStickModel: Equatable {
    var center: CGPoint
    var radius: CGFloat
    /// Fraction of radius with no output. Defaults to 0 (raw pass-through):
    /// the engine applies its own radial deadzone to gamepad axes, so any
    /// app-side zone is additive on top of it (see TouchTuning.default).
    var deadZone: CGFloat = 0

    func axes(for touch: CGPoint) -> (x: Float, y: Float) {
        let dx = touch.x - center.x
        let dy = touch.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        let deadDistance = deadZone * radius
        guard distance > deadDistance else { return (0, 0) }

        let clamped = min(distance, radius)
        let scaled = (clamped - deadDistance) / (radius - deadDistance)
        return (Float(dx / distance * scaled), Float(dy / distance * scaled))
    }

    func knobPosition(for touch: CGPoint) -> CGPoint {
        let dx = touch.x - center.x
        let dy = touch.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        guard distance > radius else { return touch }
        return CGPoint(x: center.x + dx / distance * radius,
                       y: center.y + dy / distance * radius)
    }
}
