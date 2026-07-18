import UIKit

/// Transparent full-screen overlay: left region = movement stick,
/// right region = drag-to-turn, plus edge-anchored buttons. Pure UIKit —
/// SwiftUI can't live inside SDL's UIWindow without a hosting controller,
/// and we want zero interference with SDL's own event handling.
final class TouchOverlayView: UIView {
    private let gamepad: TouchGamepad
    private let scheme: TouchControlScheme

    private var stickTouch: UITouch?
    private var stickModel = TouchStickModel(center: .zero, radius: 60)
    private var turnTouch: UITouch?
    private var turnModel = TouchStickModel(center: .zero, radius: 60)
    private var lastTurnX: CGFloat = 0

    private let stickBase = CAShapeLayer()
    private let stickKnob = CAShapeLayer()
    private let turnBase = CAShapeLayer()
    private let turnKnob = CAShapeLayer()

    init(gamepad: TouchGamepad, scheme: TouchControlScheme = .defaultScheme) {
        self.gamepad = gamepad
        self.scheme = scheme
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        accessibilityIdentifier = "touchOverlay"

        for layer in [stickBase, stickKnob, turnBase, turnKnob] {
            layer.fillColor = UIColor.white.withAlphaComponent(0.12).cgColor
            layer.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
            layer.lineWidth = 2
            layer.isHidden = true
            self.layer.addSublayer(layer)
        }

        // --- Button wiring audit ---
        // Every control below is wired against Woof!'s *default* gamepad
        // binding, verified directly in Engine/woof/src/m_input.c (not
        // guessed -- two rounds of device testing (FIRE/USE, then MAP) each
        // found a control that had been guessed wrong and silently did
        // nothing). Check this table before wiring a new button:
        //
        //   Control       Wired to (TouchButton)   Woof default (m_input.c)
        //   -----------   ----------------------   --------------------------------
        //   FIRE          RIGHT_TRIGGER axis        input_fire: GAMEPAD_RIGHT_TRIGGER
        //                 (not a button at all --   (:656,658) -- synthesized from the
        //                 see setFireTrigger)        trigger axis, see TouchButton's
        //                                            doc comment in TouchGamepad.swift
        //   USE           .south                     input_use: GAMEPAD_SOUTH (:654-655)
        //   weapon prev   .leftShoulder              input_prevweapon: GAMEPAD_LEFT_SHOULDER
        //                                             (:659-660)
        //   weapon next   .rightShoulder             input_nextweapon: GAMEPAD_RIGHT_SHOULDER
        //                                             (:661-662)
        //   MAP           .north                     input_map: GAMEPAD_NORTH (:689-690).
        //                                             Previously wired to .back
        //                                             (SDL_GAMEPAD_BUTTON_BACK), which has
        //                                             no entry anywhere in default_inputs --
        //                                             guessed, unbound, silently did nothing.
        //   MENU (≡)      .start                     input_menu_escape: GAMEPAD_START
        //                                             (:618-622) -- *not* input_escape
        //                                             (m_input.c:633, key-only, no gamepad
        //                                             binding). MN_Responder's !menuactive
        //                                             branch (mn_menu.c:3193-3204) treats a
        //                                             MENU_ESCAPE action (derived from
        //                                             input_menu_escape) as "open the menu"
        //                                             when none is active, "back/cancel"
        //                                             once one already is -- confirmed correct,
        //                                             not changed by either fix round.
        addButton("FIRE", id: "fireButton", size: 84) { [weak self] down in
            self?.gamepad.setFireTrigger(down: down)
        }
        addButton("USE", id: "useButton", size: 64) { [weak self] down in
            self?.gamepad.setButton(.south, down: down)
        }
        addButton("◀", id: "weaponPrevButton", size: 48) { [weak self] down in
            self?.gamepad.setButton(.leftShoulder, down: down)
        }
        addButton("▶", id: "weaponNextButton", size: 48) { [weak self] down in
            self?.gamepad.setButton(.rightShoulder, down: down)
        }
        addButton("MAP", id: "automapButton", size: 48) { [weak self] down in
            self?.gamepad.setButton(.north, down: down)
        }
        addButton("≡", id: "menuButton", size: 48) { [weak self] down in
            self?.gamepad.setButton(.start, down: down)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Buttons

    private var buttons: [OverlayButton] = []

    private func addButton(_ title: String, id: String, size: CGFloat,
                           onPress: @escaping (Bool) -> Void) {
        let control = OverlayButton(title: title, size: size, onPress: onPress)
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
            } else if scheme.usesDragTurn && turnTouch == nil && point.x >= bounds.width * 0.4 {
                turnTouch = touch
                lastTurnX = point.x
                turnModel = TouchStickModel(center: point, radius: 60)
                drawTurnStick(at: point)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            if touch == stickTouch {
                let axes = stickModel.axes(for: point)
                gamepad.setMovement(x: axes.x, y: axes.y, scheme: scheme)
                moveKnob(stickKnob, to: stickModel.knobPosition(for: point))
            } else if touch == turnTouch {
                gamepad.turn(byPoints: point.x - lastTurnX)
                lastTurnX = point.x
                moveKnob(turnKnob, to: turnModel.knobPosition(for: point))
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
                gamepad.setMovement(x: 0, y: 0, scheme: scheme)
                stickBase.isHidden = true
                stickKnob.isHidden = true
            } else if touch == turnTouch {
                turnTouch = nil
                turnBase.isHidden = true
                turnKnob.isHidden = true
            }
        }
    }

    // MARK: Stick drawing

    private func drawStick(at center: CGPoint) {
        stickBase.path = UIBezierPath(
            arcCenter: center, radius: 60, startAngle: 0,
            endAngle: .pi * 2, clockwise: true).cgPath
        moveKnob(stickKnob, to: center)
        stickBase.isHidden = false
        stickKnob.isHidden = false
    }

    /// Turn-region visuals (modern scheme only, gated by usesDragTurn in
    /// touchesBegan): same base/knob circle look as the movement stick, so
    /// the previously-invisible right turn region now shows where the
    /// finger landed and how far it has dragged. The knob still only feeds
    /// the x-drag delta into gamepad.turn(byPoints:) -- this model just
    /// gives it a place to visually clamp to, matching the movement stick.
    private func drawTurnStick(at center: CGPoint) {
        turnBase.path = UIBezierPath(
            arcCenter: center, radius: 60, startAngle: 0,
            endAngle: .pi * 2, clockwise: true).cgPath
        moveKnob(turnKnob, to: center)
        turnBase.isHidden = false
        turnKnob.isHidden = false
    }

    private func moveKnob(_ knob: CAShapeLayer, to point: CGPoint) {
        knob.path = UIBezierPath(
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
