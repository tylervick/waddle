import Foundation

/// How the touch overlay's movement stick maps onto SDL gamepad axes.
///
/// User feedback from on-device testing: twin-stick strafe (the original,
/// only behavior) feels wrong for classic WADs, where turning belongs on
/// the stick and there's no expectation of a separate strafe axis. That made
/// `classic` the default from 2026-07-18 until issue #534, which made
/// `modern` (the original twin-stick plus drag-to-turn) the default for new
/// installs while every earlier install keeps the scheme it was on (see
/// `settleStoredScheme`).
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

    static let defaultScheme: TouchControlScheme = .modern
    /// What an install with nothing stored played on before `defaultScheme`
    /// became `.modern`. Historical, not a preference: it must not follow
    /// a later change of `defaultScheme`.
    static let previousDefault: TouchControlScheme = .classic
    static let userDefaultsKey = "touchControlScheme"

    /// Stores a scheme on an install that has none, once, at launch, so that
    /// changing `defaultScheme` never moves a player who did not choose.
    ///
    /// An unset key used to mean "the default in code", and an existing
    /// install that never opened Settings looks exactly like a new one in
    /// `UserDefaults`. So the caller says which it is, from something an
    /// earlier launch left behind (`LibraryService.isExistingInstall`), and
    /// this stores `previousDefault` for an existing install and
    /// `defaultScheme` for a new one. After it has run the key is always
    /// set, so a later launch, when the library is no longer empty, finds a
    /// value and does nothing. A stored, valid scheme is never touched.
    static func settleStoredScheme(isExistingInstall: Bool, defaults: UserDefaults = .standard) {
        if let raw = defaults.string(forKey: userDefaultsKey),
           TouchControlScheme(rawValue: raw) != nil {
            return
        }
        let scheme = isExistingInstall ? previousDefault : defaultScheme
        defaults.set(scheme.rawValue, forKey: userDefaultsKey)
    }

    /// Reads the persisted scheme, falling back to `defaultScheme` if unset
    /// or unrecognized. Used by OverlayPresenter at overlay-install time; a
    /// SwiftUI view should prefer `@AppStorage(TouchControlScheme
    /// .userDefaultsKey)` (this type is String-RawRepresentable, so
    /// @AppStorage works directly) so the Play tab picker and this read stay
    /// on the same key.
    ///
    /// Test-only override (Debug builds only): `WADDLE_TOUCH_SCHEME`
    /// ("classic"/"modern") in the process environment wins over
    /// UserDefaults, letting a UITest pin the scheme without depending on
    /// @AppStorage/UserDefaults timing -- same test-seam pattern as
    /// `WADDLE_AUTOQUIT_SECONDS` (EngineSession) and
    /// `WADDLE_FORCE_TOUCH_OVERLAY` (OverlayPresenter). Never set
    /// outside a test launch environment.
    static func current(defaults: UserDefaults = .standard) -> TouchControlScheme {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["WADDLE_TOUCH_SCHEME"],
           let scheme = TouchControlScheme(rawValue: raw) {
            return scheme
        }
        #endif
        guard let raw = defaults.string(forKey: userDefaultsKey) else { return defaultScheme }
        return TouchControlScheme(rawValue: raw) ?? defaultScheme
    }

    /// Resolves a playable item's optional per-item override against the
    /// global default: a non-nil, valid override wins over the global default.
    /// The DEBUG `WADDLE_TOUCH_SCHEME` test-seam still wins over everything
    /// (delegating to `current`) so UITests stay deterministic regardless of
    /// any item override.
    static func effective(override raw: String?,
                          defaults: UserDefaults = .standard) -> TouchControlScheme {
        #if DEBUG
        if let seamRaw = ProcessInfo.processInfo.environment["WADDLE_TOUCH_SCHEME"],
           TouchControlScheme(rawValue: seamRaw) != nil {
            return current(defaults: defaults)
        }
        #endif
        if let raw, let scheme = TouchControlScheme(rawValue: raw) { return scheme }
        return current(defaults: defaults)
    }

    /// Human-readable label for menus/pickers (`.classic` -> "Classic",
    /// `.modern` -> "Modern").
    var displayLabel: String {
        switch self {
        case .classic: return "Classic"
        case .modern: return "Modern"
        }
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
