import CoreGraphics

/// The automap inputs a touch gesture holds down (issue #113). The engine
/// pans and zooms the automap while a bound key is HELD (`AM_Responder`
/// reads `M_InputActivated`/`Deactivated` for the arrows, '=' and '-'), so a
/// gesture translates into "which keys should be down right now", and the
/// overlay injects the keydown/keyup edges as that set changes.
///
/// An `OptionSet` in one byte on purpose: the issue's performance guard asks
/// for bounded work per gesture event, and a set that allocates nothing is
/// half of that (the other half is `AutomapGestureTranslator` holding no
/// state). `AutomapGestureTests` pins both.
struct AutomapKeys: OptionSet, Equatable {
    let rawValue: UInt8

    static let panLeft = AutomapKeys(rawValue: 1 << 0)
    static let panRight = AutomapKeys(rawValue: 1 << 1)
    static let panUp = AutomapKeys(rawValue: 1 << 2)
    static let panDown = AutomapKeys(rawValue: 1 << 3)
    static let zoomIn = AutomapKeys(rawValue: 1 << 4)
    static let zoomOut = AutomapKeys(rawValue: 1 << 5)

    /// The Doom key codes `AM_Responder`'s default bindings read
    /// (`Engine/woof/src/m_input.c`: `input_map_left/right/up/down` are the
    /// arrows, `input_map_zoomin/out` are '=' and '-'; the codes are
    /// `doomkeys.h`'s). What `WoofIOS_InjectKey` is handed.
    var engineKeyCodes: [Int32] {
        var codes: [Int32] = []
        if contains(.panLeft) { codes.append(0xac) }   // KEY_LEFTARROW
        if contains(.panRight) { codes.append(0xae) }  // KEY_RIGHTARROW
        if contains(.panUp) { codes.append(0xad) }     // KEY_UPARROW
        if contains(.panDown) { codes.append(0xaf) }   // KEY_DOWNARROW
        if contains(.zoomIn) { codes.append(0x3d) }    // '='
        if contains(.zoomOut) { codes.append(0x2d) }   // '-'
        return codes
    }
}

/// Gesture deltas -> `AutomapKeys`, as pure math over supplied values: no
/// UIKit, no SDL, no clock. Stateless by design (see `AutomapKeys`); the
/// overlay owns the touches, the previous points, and the idle timer that
/// releases the keys when a finger stops moving.
struct AutomapGestureTranslator {
    /// A drag component smaller than this, in points per event, is finger
    /// jitter and holds nothing on that axis.
    static let panThreshold: CGFloat = 2
    /// A pinch ratio this close to 1 is two fingers holding still.
    static let zoomThreshold: CGFloat = 0.01

    /// The keys a one-finger drag by `delta` (points, UIKit coordinates: y
    /// grows downward) should hold. The map CONTENT follows the finger, so
    /// the engine's view window moves the other way: dragging right holds
    /// pan-left, dragging down holds pan-up.
    func keys(forDrag delta: CGPoint) -> AutomapKeys {
        var keys: AutomapKeys = []
        if delta.x >= Self.panThreshold { keys.insert(.panLeft) }
        if delta.x <= -Self.panThreshold { keys.insert(.panRight) }
        if delta.y >= Self.panThreshold { keys.insert(.panUp) }
        if delta.y <= -Self.panThreshold { keys.insert(.panDown) }
        return keys
    }

    /// The keys a two-finger pinch should hold, from this event's finger
    /// distance over the previous event's: spreading (> 1) zooms in.
    func keys(forPinchRatio ratio: CGFloat) -> AutomapKeys {
        if ratio >= 1 + Self.zoomThreshold { return .zoomIn }
        if ratio <= 1 - Self.zoomThreshold { return .zoomOut }
        return []
    }
}
