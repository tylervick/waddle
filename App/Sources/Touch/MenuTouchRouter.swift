import CoreGraphics

/// What a free-area touch means while the engine's menu is up. Pure, like
/// `TouchTrackRouter`, so `WaddleTests` pins the rule without UIKit.
///
/// The one subtlety is the stick column. The movement stick navigates the
/// menu through the virtual pad (a held deflection auto-repeats MENU_DOWN),
/// and a drag there must keep doing that. A touch that begins in the column
/// is therefore *pending*: if it travels past `tapSlop` it is the stick, as
/// it always was; if it lifts in place it is a tap on whatever item is
/// under it. Everywhere else a touch drives the pointer from the moment it
/// lands, so an item highlights on touch-down and a slider drags.
struct MenuTouchRouter {
    /// Travel allowed before a pending touch stops being a tap, in overlay
    /// points: a fingertip's wobble, well under the stick's dead zone.
    static let tapSlop: CGFloat = 10

    enum Began: Equatable {
        /// Drive the engine's menu pointer: post the position, then a press.
        case pointer
        /// Stick column: decide on move (stick) or on lift (tap).
        case pending
        /// A second finger, or a near-miss on a button. Do nothing.
        case ignore
        /// No menu is up: the caller's stick/turn routing applies.
        case passThrough
    }

    enum Ended: Equatable {
        case tap
        case none
    }

    func began(menuActive: Bool, trackRoute: TouchTrackRoute,
               nearButton: Bool, pointerOwned: Bool) -> Began {
        guard menuActive else { return .passThrough }
        if nearButton { return .ignore }
        if trackRoute == .stick { return .pending }
        return pointerOwned ? .ignore : .pointer
    }

    func pendingBecameStick(from start: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) > Self.tapSlop
    }

    func ended(pendingFrom start: CGPoint, at point: CGPoint) -> Ended {
        pendingBecameStick(from: start, to: point) ? .none : .tap
    }
}
