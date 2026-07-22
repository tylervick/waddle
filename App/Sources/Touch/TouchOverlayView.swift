import UIKit
import WoofEngine

/// Transparent full-screen overlay: left region = movement stick,
/// right region = drag-to-turn, plus edge-anchored buttons. Pure UIKit —
/// SwiftUI can't live inside SDL's UIWindow without a hosting controller,
/// and we want zero interference with SDL's own event handling.
final class TouchOverlayView: UIView {
    private let gamepad: TouchGamepad
    private let scheme: TouchControlScheme
    private let tuning: TouchTuning
    private let debugHUDEnabled: Bool

    private var stickTouch: UITouch?
    private var stickModel = TouchStickModel(center: .zero, radius: 60)
    private var turnTouch: UITouch?
    private var turnModel = TouchStickModel(center: .zero, radius: 60)
    private var lastTurnX: CGFloat = 0

    private let stickBase = CAShapeLayer()
    private let stickKnob = CAShapeLayer()
    private let turnBase = CAShapeLayer()
    private let turnKnob = CAShapeLayer()

    private var debugHUDLabel: UILabel?
    private var debugHUDTimer: Timer?
    private var menuPolicyTimer: Timer?
    private let keyboard: TouchKeyboard
    private var keyboardActive = false
    private let keyboardActiveMarker = UIView()
    private var summonTouches = Set<UITouch>()
    private var summonArmed = true

    init(gamepad: TouchGamepad, scheme: TouchControlScheme = .defaultScheme,
         tuning: TouchTuning = .default, debugHUDEnabled: Bool = false) {
        self.gamepad = gamepad
        self.scheme = scheme
        self.tuning = tuning
        self.debugHUDEnabled = debugHUDEnabled
        self.keyboard = TouchKeyboard(injector: gamepad)
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
        //
        // Second thing to check before wiring a new button: m_input.c's
        // *menu-navigation* input table (input_menu_up/down/escape/clear/
        // etc., m_input.c:560-630, `M_InputPredefined`/`M_UpdateConfirmCancel`)
        // reuses the same physical gamepad buttons as the gameplay table
        // above for a *different* purpose while a menu is on screen --
        // it's a separate binding set Woof switches to contextually, not
        // an override of the gameplay one. NORTH is exactly this case:
        // correct as MAP's gameplay default, but m_input.c:624-628 also
        // binds it to input_menu_clear, and SOUTH (USE) doubles as
        // gamepad_confirm (m_input.c:564,576) in that same table. Combined,
        // MAP+USE in the Load/Save menu arms and confirms a savegame
        // delete (mn_menu.c:3368-3378, :2806-2814) -- see
        // updateAutomapAvailability() below, which hides MAP whenever
        // WoofIOS_IsMenuActive() reports a menu on screen so the overlay
        // can't trigger this. A future button add must check *both*
        // tables, not just the gameplay one.
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

        // Always on -- independent of debugHUDEnabled below, which is
        // opt-in and off by default. This one is a correctness fix (see
        // the wiring audit above), not a debug aid.
        startMenuPolicyTimer()

        // Soft keyboard: four-finger tap summons the iOS keyboard over the
        // live game for cheat/text entry (see the design spec). The field is
        // an invisible funnel; Return commits a save-name (only in that
        // context) then dismisses.
        addSubview(keyboard.field)
        keyboard.onReturn = { [weak self] in
            guard let self else { return }
            if self.gamepad.currentTextInputContext() == .saveName {
                self.gamepad.injectMenuConfirm()
            }
            self.dismissKeyboard()
        }

        // Small but non-zero frame in a corner: a zero-frame accessibility
        // element can be treated as off-screen and go missing from the
        // XCUITest tree. Non-interactive and effectively invisible.
        keyboardActiveMarker.frame = CGRect(x: 2, y: 2, width: 2, height: 2)
        keyboardActiveMarker.accessibilityIdentifier = "softKeyboardActive"
        keyboardActiveMarker.isAccessibilityElement = true
        keyboardActiveMarker.isUserInteractionEnabled = false
        keyboardActiveMarker.isHidden = true
        addSubview(keyboardActiveMarker)

        if debugHUDEnabled {
            let label = UILabel()
            label.accessibilityIdentifier = "sessionDebugHUD"
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = UIColor.white.withAlphaComponent(0.6)
            label.backgroundColor = UIColor.black.withAlphaComponent(0.3)
            label.textAlignment = .center
            label.isUserInteractionEnabled = false // never intercepts touches
            addSubview(label)
            debugHUDLabel = label
            startDebugHUDTimer()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Torn down here rather than `deinit`: Timer is non-Sendable, and
    // `deinit` runs in a nonisolated context that Swift 6 won't let touch
    // it. OverlayPresenter.end() already calls removeFromSuperview() on
    // this view the instant a session ends (on the main actor), so that's
    // the reliable, correctly-isolated place to invalidate both timers.
    override func removeFromSuperview() {
        debugHUDTimer?.invalidate()
        debugHUDTimer = nil
        menuPolicyTimer?.invalidate()
        menuPolicyTimer = nil
        if keyboard.isVisible { keyboard.dismiss() }
        super.removeFromSuperview()
    }

    // MARK: Menu-context automap suppression (always on, see wiring audit)

    /// MAP (NORTH) doubles as input_menu_clear in Woof's menu-navigation
    /// input table -- see the wiring audit's second table. Lightweight
    /// always-on poll (not gated on the debug HUD toggle) so the overlay
    /// never lets a menu-context tap on MAP through. Restores the button
    /// the instant WoofIOS_IsMenuActive() reports the menu closed.
    private func startMenuPolicyTimer() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateAutomapAvailability()
            self?.updateKeyboardForContext()
        }
        RunLoop.main.add(timer, forMode: .common)
        menuPolicyTimer = timer
        updateAutomapAvailability()
    }

    private func updateAutomapAvailability() {
        let hideForMenu = WoofIOS_IsMenuActive()
        buttons.first { $0.accessibilityIdentifier == "automapButton" }?.isHidden = hideForMenu
    }

    // MARK: Soft keyboard (four-finger tap; see design spec)

    /// Four fingers (not three): normal play uses at most ~2-3 touches, so
    /// four is unambiguous, and it matches id's classic iOS DOOM gesture.
    ///
    /// Detected directly from touchesBegan/endTouches (below) rather than a
    /// UITapGestureRecognizer. Diagnosed by instrumentation (KVO on `state`,
    /// a UIGestureRecognizerDelegate, and a file-write inside the action) in
    /// the simulator: a UITapGestureRecognizer attached to this same view --
    /// even with completely default settings (single touch,
    /// cancelsTouchesInView left true) -- reliably reaches `.recognized`,
    /// yet its target-action is never invoked. SDL owns this UIWindow
    /// directly (no UIViewController-hosted scene backs it -- see the class
    /// doc comment), which is the most likely reason UIKit's gesture
    /// environment doesn't complete the normal recognize-then-send-actions
    /// step here, even though plain responder-chain touch delivery
    /// (touchesBegan/Moved/Ended, which OverlayButton and this class both
    /// rely on elsewhere) works reliably. Tracking touches directly
    /// sidesteps the broken step entirely.
    private func updateSummonTracking(began: Set<UITouch>) {
        summonTouches.formUnion(began)
        if summonArmed && summonTouches.count >= 4 {
            summonArmed = false
            handleSummonTap()
        }
    }

    private func handleSummonTap() {
        let ctx = gamepad.currentTextInputContext()
        if keyboard.isVisible {
            dismissKeyboard()
        } else if KeyboardGate.shouldPresentOnTap(context: ctx) {
            presentKeyboard()
        }
    }

    /// Auto-present for save-name entry / auto-dismiss on leaving a text
    /// context. Called from the same 0.25s poll as automap suppression.
    private func updateKeyboardForContext() {
        switch KeyboardGate.pollCommand(context: gamepad.currentTextInputContext(),
                                        isVisible: keyboard.isVisible) {
        case .present: presentKeyboard()
        case .dismiss: dismissKeyboard()
        case .none: break
        }
    }

    private func presentKeyboard() {
        // Interaction guard: stop movement and make the gameplay controls
        // inert while typing, so touches near or under the keyboard cannot
        // steer or fire.
        gamepad.setMovement(x: 0, y: 0, scheme: scheme)
        stickTouch = nil
        turnTouch = nil
        stickBase.isHidden = true
        stickKnob.isHidden = true
        turnBase.isHidden = true
        turnKnob.isHidden = true
        keyboardActive = true
        for button in buttons { button.isUserInteractionEnabled = false }
        keyboard.present()
        keyboardActiveMarker.isHidden = false
    }

    private func dismissKeyboard() {
        keyboard.dismiss()
        keyboardActive = false
        for button in buttons { button.isUserInteractionEnabled = true }
        keyboardActiveMarker.isHidden = true
    }

    // MARK: Debug HUD (opt-in, "Show Debug Info" toggle on the Play tab)

    /// Live telemetry refreshed on a main-runloop timer (not just once at
    /// install): commit/branch identify exactly which build is running on
    /// a test device, active scheme confirms which control mapping is live,
    /// and the touch-event count + trigger value are the same debug
    /// counters TouchControlsTests reads post-session, but updating in
    /// real time here -- e.g. this is what would have shown the FIRE
    /// autofire bug's stuck ~0.5 trigger value live, during the session,
    /// rather than only after the fact.
    private func startDebugHUDTimer() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateDebugHUD()
        }
        RunLoop.main.add(timer, forMode: .common)
        debugHUDTimer = timer
        updateDebugHUD()
    }

    private func updateDebugHUD() {
        let trigger = WoofIOS_DebugTriggerValue()
        debugHUDLabel?.text = String(
            format: "build %@ (%@) · %@ · events %d · trigger %.2f · turn %.2f · dz %.2f · move %.2f",
            BuildInfo.commit, BuildInfo.branch, scheme == .classic ? "classic" : "modern",
            WoofIOS_DebugTouchEventCount(), trigger,
            tuning.turnSpeed, tuning.stickDeadZone, tuning.moveSensitivity)
    }

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
        // The debug HUD claims a thin strip at the very top edge; push the
        // top button row down to clear it so the HUD never overlaps them
        // (only takes effect when the "Show Debug Info" toggle is on --
        // zero layout change otherwise).
        let hudReservedHeight: CGFloat = debugHUDEnabled ? 22 : 0
        if let debugHUDLabel {
            debugHUDLabel.frame = CGRect(x: b.minX + inset.left, y: b.minY + inset.top,
                                         width: b.width - inset.left - inset.right,
                                         height: hudReservedHeight)
        }
        let topRowY = b.minY + inset.top + hudReservedHeight
        // Right-hand cluster: FIRE big, USE above it, shoulders top corners,
        // MAP + MENU at top edge.
        place("fireButton", x: b.maxX - inset.right - 70, y: b.maxY - inset.bottom - 90)
        place("useButton", x: b.maxX - inset.right - 160, y: b.maxY - inset.bottom - 60)
        place("weaponPrevButton", x: b.minX + inset.left + 40, y: topRowY + 40)
        place("weaponNextButton", x: b.maxX - inset.right - 40, y: topRowY + 40)
        place("automapButton", x: b.midX - 40, y: topRowY + 32)
        place("menuButton", x: b.midX + 40, y: topRowY + 32)
    }

    private func place(_ id: String, x: CGFloat, y: CGFloat) {
        buttons.first { $0.accessibilityIdentifier == id }?.center = CGPoint(x: x, y: y)
    }

    // MARK: Touches (stick + turn; buttons handle their own)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Snapshot BEFORE updateSummonTracking: a four-finger dismiss tap
        // flips keyboardActive false mid-call (updateSummonTracking ->
        // handleSummonTap -> dismissKeyboard), and without this snapshot the
        // guard below would then see false and let those same four dismiss
        // touches fall through into stick/turn assignment, steering the
        // player. The tracking call must still run first so a tap can dismiss
        // while the keyboard is active, not only summon it.
        let wasKeyboardActive = keyboardActive
        updateSummonTracking(began: touches)
        if wasKeyboardActive || keyboardActive { return }
        for touch in touches {
            let point = touch.location(in: self)
            if stickTouch == nil && point.x < bounds.width * 0.4 {
                stickTouch = touch
                stickModel = TouchStickModel(center: point, radius: 60,
                                             deadZone: CGFloat(tuning.stickDeadZone))
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
        if keyboardActive { return }
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
        summonTouches.subtract(touches)
        if summonTouches.isEmpty { summonArmed = true }
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
