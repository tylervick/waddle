import UIKit

/// The drag-and-drop layout editor's canvas (issue #115): the six overlay
/// buttons, drawn with the same `OverlayButton` class and placed by the same
/// `TouchOverlayLayout` the session uses, over a black field with Doom's
/// status-bar band marked. A drag that begins inside a button's circle moves
/// that button; the offset stored is the clamped one for where the button
/// ended up, so the persisted layout is the one the player saw.
///
/// Pure UIKit like `TouchOverlayView`, and hosted by `TouchLayoutEditorView`.
/// The buttons do not take touches here (`isUserInteractionEnabled = false`):
/// the canvas owns every drag, so the press-and-hold machinery of
/// `OverlayButton` never fires in the editor. `beginDrag`/`continueDrag`/
/// `endDrag` are the whole behaviour, and `TouchLayoutEditorCanvasTests`
/// drives them without a `UITouch`.
final class TouchLayoutEditorCanvas: UIView {
    /// The editor's buttons are addressable under their own identifiers,
    /// distinct from the session overlay's, so a UI test can never confuse
    /// the two.
    static func identifier(for control: TouchOverlayControl) -> String {
        "layoutEditor.\(control.rawValue)"
    }

    /// The glyphs `TouchOverlayView` draws, so the editor looks like the game.
    static let titles: [TouchOverlayControl: String] = [
        .fire: "FIRE", .use: "USE", .weaponPrev: "◀", .weaponNext: "▶", .automap: "MAP", .menu: "≡",
    ]

    /// The working copy. Setting it (Reset, or the host restoring a saved
    /// table) relays out immediately.
    var overrides: TouchOverlayLayoutOverrides {
        didSet { if overrides != oldValue { setNeedsLayout() } }
    }

    /// Called once per drag movement with the updated table, so the host can
    /// keep its own copy current (and save it on Done).
    var onChange: ((TouchOverlayLayoutOverrides) -> Void)?

    private var buttons: [TouchOverlayControl: OverlayButton] = [:]
    private let statusBarBand = UIView()
    private let statusBarLabel = UILabel()
    /// The control being dragged and where in it the finger landed (finger
    /// minus center), so the button follows the finger without jumping to it.
    private var drag: (control: TouchOverlayControl, grab: CGPoint)?

    init(overrides: TouchOverlayLayoutOverrides) {
        self.overrides = overrides
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = false
        accessibilityIdentifier = "touchLayoutEditor"

        statusBarBand.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        statusBarBand.isUserInteractionEnabled = false
        addSubview(statusBarBand)
        statusBarLabel.text = "Doom status bar"
        statusBarLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusBarLabel.textColor = UIColor.white.withAlphaComponent(0.35)
        statusBarLabel.textAlignment = .center
        statusBarLabel.isUserInteractionEnabled = false
        statusBarBand.addSubview(statusBarLabel)

        for control in TouchOverlayControl.allCases {
            let button = OverlayButton(title: Self.titles[control] ?? control.rawValue,
                                       size: control.baseDiameter) { _ in }
            button.isUserInteractionEnabled = false // the canvas owns the drag
            button.accessibilityIdentifier = Self.identifier(for: control)
            buttons[control] = button
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Live geometry for the current bounds, exactly as the session computes
    /// it (no debug-HUD reserve: the editor has no strip).
    private var layout: TouchOverlayLayout {
        TouchOverlayLayout(bounds: bounds, safeAreaInsets: safeAreaInsets, hudReserve: 0,
                           overrides: overrides)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let layout = self.layout
        let usable = bounds.inset(by: safeAreaInsets)
        statusBarBand.frame = CGRect(x: usable.minX, y: usable.maxY - layout.statusBarReserve,
                                     width: usable.width, height: layout.statusBarReserve)
        statusBarLabel.frame = statusBarBand.bounds
        for (control, button) in buttons {
            button.frame = layout.frame(for: control)
        }
    }

    /// Where the editor currently shows `control`, in canvas coordinates.
    func frame(for control: TouchOverlayControl) -> CGRect {
        buttons[control]?.frame ?? .zero
    }

    // MARK: Drag

    /// Starts a drag if `point` is inside a button's drawn circle (the same
    /// inscribed-circle rule `OverlayButton.point(inside:)` applies in the
    /// session, so a square corner is a miss here too). Returns whether it did.
    @discardableResult
    func beginDrag(at point: CGPoint) -> Bool {
        guard drag == nil else { return false }
        for control in TouchOverlayControl.allCases {
            guard let button = buttons[control] else { continue }
            let frame = button.frame
            let radius = min(frame.width, frame.height) / 2
            let dx = point.x - frame.midX, dy = point.y - frame.midY
            if dx * dx + dy * dy <= radius * radius {
                drag = (control, CGPoint(x: dx, y: dy))
                button.layer.borderColor = UIColor.systemYellow.cgColor
                bringSubviewToFront(button)
                return true
            }
        }
        return false
    }

    /// Moves the dragged button so the grab point stays under the finger,
    /// clamped into the window by the layout, and reports the new table.
    func continueDrag(to point: CGPoint) {
        guard let drag else { return }
        let center = CGPoint(x: point.x - drag.grab.x, y: point.y - drag.grab.y)
        overrides[drag.control] = layout.clampedOverrideOffset(placing: drag.control, at: center)
        onChange?(overrides)
    }

    func endDrag() {
        if let drag, let button = buttons[drag.control] {
            button.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        }
        drag = nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        beginDrag(at: touch.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        continueDrag(to: touch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { endDrag() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { endDrag() }
}
