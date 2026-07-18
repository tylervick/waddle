import Foundation

/// How the touch overlay's movement stick maps onto SDL gamepad axes.
///
/// User feedback from on-device testing: twin-stick strafe (the original,
/// only behavior) feels wrong for classic WADs, where turning belongs on
/// the stick and there's no expectation of a separate strafe axis. `classic`
/// is now the default; `modern` keeps the original twin-stick-plus-drag-turn
/// behavior for players who want it.
enum TouchControlScheme: String, CaseIterable {
    /// Stick X turns (Woof's RIGHTX axis), stick Y moves forward/back. No
    /// strafe axis is driven. The right side of the overlay hosts buttons
    /// only -- no drag-to-turn gesture or visuals.
    case classic
    /// Stick drives LEFTX/LEFTY (twin-stick strafe + forward/back). Turning
    /// is a separate right-side drag gesture, fed through the shim's turn
    /// accumulator (TouchGamepad.turn(byPoints:)), independent of any SDL
    /// gamepad axis.
    case modern

    static let defaultScheme: TouchControlScheme = .classic
    static let userDefaultsKey = "touchControlScheme"

    /// Reads the persisted scheme, falling back to `defaultScheme` if unset
    /// or unrecognized. Used by OverlayPresenter at overlay-install time; a
    /// SwiftUI view should prefer `@AppStorage(TouchControlScheme
    /// .userDefaultsKey)` (this type is String-RawRepresentable, so
    /// @AppStorage works directly) so the Play tab picker and this read stay
    /// on the same key.
    ///
    /// Test-only override: `BOOMBOX_TOUCH_SCHEME` ("classic"/"modern") in
    /// the process environment wins over UserDefaults, letting a UITest pin
    /// the scheme without depending on @AppStorage/UserDefaults timing --
    /// same test-seam pattern as `BOOMBOX_AUTOQUIT_SECONDS` (EngineSession)
    /// and `BOOMBOX_FORCE_TOUCH_OVERLAY` (OverlayPresenter). Never set
    /// outside a test launch environment.
    static func current(defaults: UserDefaults = .standard) -> TouchControlScheme {
        if let raw = ProcessInfo.processInfo.environment["BOOMBOX_TOUCH_SCHEME"],
           let scheme = TouchControlScheme(rawValue: raw) {
            return scheme
        }
        guard let raw = defaults.string(forKey: userDefaultsKey) else { return defaultScheme }
        return TouchControlScheme(rawValue: raw) ?? defaultScheme
    }

    /// Whether this scheme uses a separate right-side drag-to-turn gesture
    /// (and therefore draws turn-region stick visuals). `classic` routes
    /// turning through the movement stick instead, so the right side is
    /// buttons only, with no turn-touch tracking or visuals.
    var usesDragTurn: Bool {
        switch self {
        case .classic: return false
        case .modern: return true
        }
    }

    /// Pure mapping from a movement stick's raw (x, y) deflection (each in
    /// [-1, 1], as produced by TouchStickModel.axes(for:)) to the SDL
    /// gamepad axes TouchGamepad.setMovement should push. No CoreGraphics,
    /// UIKit, or SDL involved -- fully unit-testable.
    func axisMapping(stickX: Float, stickY: Float) -> TouchAxisMapping {
        switch self {
        case .classic:
            // LEFTX (strafe) stays at 0; horizontal deflection instead
            // drives RIGHTX, Woof's own turn axis (rides its own
            // mouse/joy turn-sensitivity settings).
            return TouchAxisMapping(leftX: 0, leftY: stickY, rightX: stickX)
        case .modern:
            return TouchAxisMapping(leftX: stickX, leftY: stickY, rightX: 0)
        }
    }
}

/// The three SDL gamepad axes a movement stick can drive, decoupled from
/// SDL's own axis numbering so this stays testable without importing
/// WoofEngine.
struct TouchAxisMapping: Equatable {
    var leftX: Float
    var leftY: Float
    var rightX: Float
}
