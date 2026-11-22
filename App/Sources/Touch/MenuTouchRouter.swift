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

    /// `onSaveSlot`: the touch is on a slot of the engine's Load or Save
    /// list (`TouchGamepad.isSaveSlot(at:)`). A slot's frame is drawn right
    /// across the list, and where the picture fills the window the buttons
    /// are drawn over its right-hand end (a closed iPhone Duo in landscape,
    /// issue #430). The slot is what the player sees under the finger, so
    /// it wins over a button's near-miss cushion here, and over the button
    /// itself in `buttonYieldsToSaveSlot`.
    func began(menuActive: Bool, trackRoute: TouchTrackRoute,
               nearButton: Bool, onSaveSlot: Bool = false, pointerOwned: Bool) -> Began {
        guard menuActive else { return .passThrough }
        if nearButton && !onSaveSlot { return .ignore }
        if trackRoute == .stick { return .pending }
        return pointerOwned ? .ignore : .pointer
    }

    /// Whether a touch that landed on `control`'s button belongs to the
    /// save slot drawn under it instead. Every control stands down for a
    /// slot except ≡, which is the way back out of the menu and must stay
    /// reachable wherever it has been moved to. (The Yes/No pair is not a
    /// `TouchOverlayControl`, and the engine reports no slot while a prompt
    /// is up, so a prompt's buttons never yield either.)
    func buttonYieldsToSaveSlot(_ control: TouchOverlayControl, onSaveSlot: Bool) -> Bool {
        onSaveSlot && control != .menu
    }

    /// Attract mode (title screen or demo, no menu): the stick/turn routing
    /// applies exactly as during play, so a press still engages the stick,
    /// and on top of that a lift in place opens the menu, console style.
    /// True when this touch is such a candidate.
    func isAttractTapCandidate(menuActive: Bool, attractMode: Bool, nearButton: Bool) -> Bool {
        !menuActive && attractMode && !nearButton
    }

    func pendingBecameStick(from start: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) > Self.tapSlop
    }

    func ended(pendingFrom start: CGPoint, at point: CGPoint) -> Ended {
        pendingBecameStick(from: start, to: point) ? .none : .tap
    }
}
