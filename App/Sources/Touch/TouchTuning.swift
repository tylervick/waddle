import Foundation

/// User-tunable touch-control feel, persisted in UserDefaults under
/// @AppStorage-compatible keys (the Play tab's "Control Feel" sliders write
/// them; OverlayPresenter reads them once at overlay-install time, same
/// read-once policy as the scheme picker — mid-session changes apply to the
/// next session). Pure math + clamped UserDefaults reads; no UIKit, no SDL.
struct TouchTuning: Equatable {
    /// Multiplies classic-scheme stick turn (the RIGHTX axis value) and
    /// modern-scheme drag-turn sensitivity.
    var turnSpeed: Double
    /// Feeds TouchStickModel.deadZone (fraction of the stick radius).
    var stickDeadZone: Double
    /// Scales the movement axes (LEFTY forward/back + LEFTX strafe).
    var moveSensitivity: Double

    static let turnSpeedKey = "turnSpeed"
    static let stickDeadZoneKey = "stickDeadZone"
    static let moveSensitivityKey = "moveSensitivity"

    static let turnSpeedRange = 0.25...3.0
    static let stickDeadZoneRange = 0.0...0.4
    static let moveSensitivityRange = 0.5...1.5

    /// stickDeadZone defaults to 0 because the stick feeds a virtual SDL
    /// gamepad, and Woof! already applies its own 15% radial inner deadzone
    /// (plus rescale) to gamepad axes engine-side (i_gamepad.c,
    /// joy_movement_inner_deadzone / joy_camera_inner_deadzone). An app-side
    /// zone stacks on top of that, deadening the first ~third of stick
    /// travel; the slider exists only for users who want *extra* deadzone.
    static let `default` = TouchTuning(turnSpeed: 1.0, stickDeadZone: 0.0,
                                       moveSensitivity: 1.0)

    /// Reads the persisted tuning, clamping each value into its slider range
    /// and falling back to the default for anything unset or non-numeric
    /// (a bare `double(forKey:)` would silently turn garbage into 0, which
    /// clamping would then promote to the range minimum — not the default).
    static func current(defaults: UserDefaults = .standard) -> TouchTuning {
        func read(_ key: String, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            guard let number = defaults.object(forKey: key) as? NSNumber else {
                return fallback
            }
            return min(max(number.doubleValue, range.lowerBound), range.upperBound)
        }
        return TouchTuning(
            turnSpeed: read(turnSpeedKey, turnSpeedRange, `default`.turnSpeed),
            stickDeadZone: read(stickDeadZoneKey, stickDeadZoneRange, `default`.stickDeadZone),
            moveSensitivity: read(moveSensitivityKey, moveSensitivityRange, `default`.moveSensitivity))
    }

    /// Scales a scheme-mapped axis set: turnSpeed on the turn axis (RIGHTX),
    /// moveSensitivity on the movement axes (LEFTX/LEFTY), each clamped back
    /// into SDL's [-1, 1] axis range.
    func apply(to mapping: TouchAxisMapping) -> TouchAxisMapping {
        func scale(_ value: Float, by factor: Double) -> Float {
            min(max(value * Float(factor), -1), 1)
        }
        return TouchAxisMapping(
            leftX: scale(mapping.leftX, by: moveSensitivity),
            leftY: scale(mapping.leftY, by: moveSensitivity),
            rightX: scale(mapping.rightX, by: turnSpeed))
    }

    /// Modern-scheme drag turn: the effective points-to-turn factor is the
    /// app's baseline sensitivity (TouchGamepad.turnSensitivity) times the
    /// user's turnSpeed.
    func scaledTurnSensitivity(base: Float) -> Float {
        base * Float(turnSpeed)
    }
}
