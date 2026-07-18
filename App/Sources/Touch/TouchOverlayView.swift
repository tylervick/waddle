import UIKit

/// Transparent full-screen overlay: left region = movement stick,
/// right region = drag-to-turn, plus edge-anchored buttons. Pure UIKit —
/// SwiftUI can't live inside SDL's UIWindow without a hosting controller,
/// and we want zero interference with SDL's own event handling.
final class TouchOverlayView: UIView {
    private let gamepad: TouchGamepad

    private var stickTouch: UITouch?
    private var stickModel = TouchStickModel(center: .zero, radius: 60)
    private var turnTouch: UITouch?
    private var lastTurnX: CGFloat = 0

    private let stickBase = CAShapeLayer()
    private let stickKnob = CAShapeLayer()

    init(gamepad: TouchGamepad) {
        self.gamepad = gamepad
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        accessibilityIdentifier = "touchOverlay"

        for layer in [stickBase, stickKnob] {
            layer.fillColor = UIColor.white.withAlphaComponent(0.12).cgColor
            layer.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
            layer.lineWidth = 2
            layer.isHidden = true
            self.layer.addSublayer(layer)
        }

        addButton("FIRE", id: "fireButton", button: .south, size: 84)
        addButton("USE", id: "useButton", button: .east, size: 64)
        addButton("◀", id: "weaponPrevButton", button: .leftShoulder, size: 48)
        addButton("▶", id: "weaponNextButton", button: .rightShoulder, size: 48)
        addButton("MAP", id: "automapButton", button: .back, size: 48)
        addButton("≡", id: "menuButton", button: .start, size: 48)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Buttons

    private var buttons: [OverlayButton] = []

    private func addButton(_ title: String, id: String, button: TouchButton,
                           size: CGFloat) {
        let control = OverlayButton(title: title, size: size) { [weak self] down in
            self?.gamepad.setButton(button, down: down)
        }
        control.accessibilityIdentifier = id
        buttons.append(control)
        addSubview(control)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = safeAreaInsets
        let b = bounds
        // Right-hand cluster: FIRE big, USE above it, shoulders top corners,
        // MAP + MENU at top edge.
        place("fireButton", x: b.maxX - inset.right - 70, y: b.maxY - inset.bottom - 90)
        place("useButton", x: b.maxX - inset.right - 160, y: b.maxY - inset.bottom - 60)
        place("weaponPrevButton", x: b.minX + inset.left + 40, y: b.minY + inset.top + 40)
        place("weaponNextButton", x: b.maxX - inset.right - 40, y: b.minY + inset.top + 40)
        place("automapButton", x: b.midX - 40, y: b.minY + inset.top + 32)
        place("menuButton", x: b.midX + 40, y: b.minY + inset.top + 32)
    }

    private func place(_ id: String, x: CGFloat, y: CGFloat) {
        buttons.first { $0.accessibilityIdentifier == id }?.center = CGPoint(x: x, y: y)
    }

    // MARK: Touches (stick + turn; buttons handle their own)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            if stickTouch == nil && point.x < bounds.width * 0.4 {
                stickTouch = touch
                stickModel = TouchStickModel(center: point, radius: 60)
                drawStick(at: point)
            } else if turnTouch == nil && point.x >= bounds.width * 0.4 {
                turnTouch = touch
                lastTurnX = point.x
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            if touch == stickTouch {
                let axes = stickModel.axes(for: point)
                gamepad.setMovement(x: axes.x, y: axes.y)
                moveKnob(to: stickModel.knobPosition(for: point))
            } else if touch == turnTouch {
                gamepad.turn(byPoints: point.x - lastTurnX)
                lastTurnX = point.x
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    private func endTouches(_ touches: Set<UITouch>) {
        for touch in touches {
            if touch == stickTouch {
                stickTouch = nil
                gamepad.setMovement(x: 0, y: 0)
                stickBase.isHidden = true
                stickKnob.isHidden = true
            } else if touch == turnTouch {
                turnTouch = nil
            }
        }
    }

    // MARK: Stick drawing

    private func drawStick(at center: CGPoint) {
        stickBase.path = UIBezierPath(
            arcCenter: center, radius: 60, startAngle: 0,
            endAngle: .pi * 2, clockwise: true).cgPath
        moveKnob(to: center)
        stickBase.isHidden = false
        stickKnob.isHidden = false
    }

    private func moveKnob(to point: CGPoint) {
        stickKnob.path = UIBezierPath(
            arcCenter: point, radius: 26, startAngle: 0,
            endAngle: .pi * 2, clockwise: true).cgPath
    }
}

/// A press-and-hold control (UIButton's tap gesture adds latency; Doom fire
/// must be press=down / release=up).
final class OverlayButton: UIView {
    private let onPress: (Bool) -> Void

    init(title: String, size: CGFloat, onPress: @escaping (Bool) -> Void) {
        self.onPress = onPress
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title

        layer.cornerRadius = size / 2
        backgroundColor = UIColor.white.withAlphaComponent(0.12)
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor

        let label = UILabel(frame: bounds)
        label.text = title
        label.font = .systemFont(ofSize: size * 0.28, weight: .bold)
        label.textColor = UIColor.white.withAlphaComponent(0.7)
        label.textAlignment = .center
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        backgroundColor = UIColor.white.withAlphaComponent(0.3)
        onPress(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        backgroundColor = UIColor.white.withAlphaComponent(0.12)
        onPress(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        backgroundColor = UIColor.white.withAlphaComponent(0.12)
        onPress(false)
    }
}
