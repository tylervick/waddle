import CoreGraphics

/// What a newly-begun overlay touch becomes.
enum TouchTrackRoute: Equatable {
    /// Start a movement-stick track centred on the touch point.
    case stick
    /// Start a drag-to-turn track centred on the touch point.
    case turn
    /// Claim nothing. A near-miss on a button, a region whose track is
    /// already owned by another finger, and the right-hand side under a
    /// scheme with no drag-turn all land here.
    case ignore
}

/// One overlay button as the router sees it. Only the two facts the routing
/// decision actually depends on, so the router never touches UIKit: hidden
/// buttons accept no touches, so the space they vacate is ordinary overlay.
struct TouchOverlayButtonState: Equatable {
    var frame: CGRect
    var isHidden: Bool

    init(frame: CGRect, isHidden: Bool = false) {
        self.frame = frame
        self.isHidden = isHidden
    }
}

/// The stick/turn/ignore decision `TouchOverlayView.touchesBegan` makes for
/// every new touch, as a pure value — no UIView, no UITouch, no SDL — in the
/// same spirit as `TouchOverlayLayout`, `KeyboardGate` and
/// `TouchControlScheme.axisMapping`.
///
/// It lived inline in `touchesBegan` until issue #132. Nothing CI runs could
/// reach it there: the only coverage was a `WaddleUITests` case, and that
/// suite stays off the pull-request path (`.github/workflows/ui-tests.yml`
/// runs on `push: main` and manual dispatch only). Extracting it puts the
/// decision in `WaddleTests`, which every pull request runs.
struct TouchTrackRouter {
    /// Fraction of the overlay's width that belongs to the movement stick.
    /// Everything from here rightward is the turn region under a scheme that
    /// uses drag-turn, and buttons-only under one that does not.
    static let stickColumnFraction: CGFloat = 0.4

    /// How far past a button's edge still counts as "aimed at that button",
    /// in points, so a near-miss does nothing instead of being claimed as a
    /// stick or turn track.
    ///
    /// This used to be justified by weaponPrevButton sitting at
    /// `x: minX + inset.left + 40`, inside the movement stick's own capture
    /// column, where a missed tap started a stick track and the player got
    /// movement instead of a weapon switch. `TouchOverlayLayout` has since
    /// moved both weapon buttons into the right-hand cluster, so nothing is
    /// left in the stick column and that specific collision is gone. The
    /// cushion still earns its place on the other side: in the `modern`
    /// scheme the whole right region is a drag-to-turn surface, so a
    /// near-miss on FIRE, USE or a weapon button would otherwise start a
    /// turn track and swing the view.
    ///
    /// 20pt puts the cushion just past a fingertip's radius beyond the
    /// button's edge, which is the size of the miss this is about. It is
    /// deliberately *not* scaled: it models a fingertip, and fingers are the
    /// same size on an iPad.
    static let buttonNearMissMargin: CGFloat = 20

    /// Width of the overlay, in its own coordinate space. The column split is
    /// taken from the width alone, exactly as the inline code did.
    let overlayWidth: CGFloat
    let scheme: TouchControlScheme
    let buttons: [TouchOverlayButtonState]
    let nearMissMargin: CGFloat

    init(overlayWidth: CGFloat,
         scheme: TouchControlScheme,
         buttons: [TouchOverlayButtonState],
         nearMissMargin: CGFloat = TouchTrackRouter.buttonNearMissMargin) {
        self.overlayWidth = overlayWidth
        self.scheme = scheme
        self.buttons = buttons
        self.nearMissMargin = nearMissMargin
    }

    /// x below which a touch is in the movement stick's column.
    var stickColumnLimit: CGFloat { overlayWidth * Self.stickColumnFraction }

    /// True when `point` falls inside a visible button's frame grown by
    /// `nearMissMargin`. Hidden buttons are deliberately excluded:
    /// `updateAutomapAvailability()` hides MAP whenever a menu is on screen,
    /// and a hidden button accepts no touches, so the space it vacated is
    /// ordinary overlay again and should behave like it.
    func isNearButton(_ point: CGPoint) -> Bool {
        buttons.contains { button in
            !button.isHidden
                && button.frame.insetBy(dx: -nearMissMargin, dy: -nearMissMargin).contains(point)
        }
    }

    /// Where a touch beginning at `point` should go, given which tracks are
    /// already owned by other fingers.
    ///
    /// A near-miss is rejected on **both** sides, not just the stick column.
    /// The inline version only consulted the cushion in the stick branch, so
    /// in the `modern` scheme a fingertip that missed FIRE, USE or a weapon
    /// button by a few points still started a turn track and swung the view —
    /// the exact hazard the margin's own doc comment describes. Issue #132
    /// closed that gap along with the extraction.
    func route(_ point: CGPoint, stickTracking: Bool, turnTracking: Bool) -> TouchTrackRoute {
        if isNearButton(point) { return .ignore }
        if point.x < stickColumnLimit {
            return stickTracking ? .ignore : .stick
        }
        guard scheme.usesDragTurn, !turnTracking else { return .ignore }
        return .turn
    }
}
