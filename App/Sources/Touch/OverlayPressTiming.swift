import Foundation

/// Holds an overlay button's release back until the press has lasted long
/// enough for the engine to have seen it.
///
/// The buttons drive an SDL virtual joystick, whose state SDL samples only
/// when the engine pumps events: at best once per rendered frame, at worst
/// once per 35 Hz tic. A down and an up that both land between two pumps
/// leave the sampled state unchanged, and the press never happens. Revyl's
/// farm device taps fast enough for that to be a coin flip (the debug strip
/// counted the overlay's two touch events for a USE tap while the engine's
/// button-event count did not move); XCUITest taps are long enough that the
/// simulator never showed it. See
/// docs/learnings/virtual-gamepad-tap-shorter-than-a-pump-is-lost.md.
struct OverlayPressTiming {
    /// How long a press must last before its release is forwarded.
    let minimumHold: TimeInterval
    private var pressedAt: TimeInterval?

    /// Two engine pumps at the slowest rate (35 Hz), so at least one pump
    /// observes the down even when the press starts just after a pump.
    static let engineSafe = OverlayPressTiming(minimumHold: 2.0 / 35.0)

    init(minimumHold: TimeInterval) {
        self.minimumHold = minimumHold
    }

    mutating func pressed(at time: TimeInterval) {
        pressedAt = time
    }

    /// Returns how long the caller must wait before forwarding the release:
    /// zero when the press already lasted `minimumHold`, or when there was
    /// no press to speak of.
    mutating func released(at time: TimeInterval) -> TimeInterval {
        guard let pressedAt else { return 0 }
        self.pressedAt = nil
        return max(0, minimumHold - (time - pressedAt))
    }
}
