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
    // Placeholders only: both are rebuilt at the touch point, with the
    // device-scaled `layout.stickRadius`, on every touch-begin.
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
    private let stickEngagedMarker = UIView()

    init(gamepad: TouchGamepad, scheme: TouchControlScheme,
         tuning: TouchTuning, debugHUDEnabled: Bool) {
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
        //   USE           .south                     input_use: GAMEPAD_SOUTH (:654-655).
        //                                             Previously wired to
        //                                             SDL_GAMEPAD_BUTTON_EAST (ordinal 1),
        //                                             which -- like BACK below -- has no
        //                                             default_inputs entry, so it silently
        //                                             did nothing. TouchButton no longer
        //                                             declares a case for that ordinal;
        //                                             nothing in the app drives it.
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
        addButton("FIRE", control: .fire) { [weak self] down in
            self?.gamepad.setFireTrigger(down: down)
        }
        addButton("USE", control: .use) { [weak self] down in
            self?.gamepad.setButton(.south, down: down)
        }
        addButton("◀", control: .weaponPrev) { [weak self] down in
            self?.gamepad.setButton(.leftShoulder, down: down)
        }
        addButton("▶", control: .weaponNext) { [weak self] down in
            self?.gamepad.setButton(.rightShoulder, down: down)
        }
        addButton("MAP", control: .automap) { [weak self] down in
            self?.gamepad.setButton(.north, down: down)
        }
        addButton("≡", control: .menu) { [weak self] down in
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
        keyboard.onExternalDismiss = { [weak self] in
            // Keyboard went away on its own (system dismiss / focus steal);
            // resync overlay control-lock state. dismissKeyboard() is
            // idempotent, so a redundant call is harmless.
            self?.dismissKeyboard()
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

        // Same corner-marker pattern, carrying one latching bit: "a
        // movement-stick track engaged at some point this session". It
        // latches instead of mirroring `stickTouch` live because a tap's
        // stick track is created and torn down in milliseconds -- far
        // faster than XCUITest can query the tree -- so a live mirror would
        // read "off" whether or not a track had engaged, and prove nothing.
        stickEngagedMarker.frame = CGRect(x: 6, y: 2, width: 2, height: 2)
        stickEngagedMarker.accessibilityIdentifier = "stickEngaged"
        stickEngagedMarker.isAccessibilityElement = true
        stickEngagedMarker.isUserInteractionEnabled = false
        stickEngagedMarker.isHidden = true
        addSubview(stickEngagedMarker)

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
        // Only lock the gameplay controls if the keyboard actually came up;
        // a failed becomeFirstResponder would otherwise leave controls inert
        // with no keyboard on screen (review Minor #2).
        guard keyboard.present() else { return }
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
        for button in buttons where button.accessibilityIdentifier != "menuButton" {
            button.isUserInteractionEnabled = false
        }
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

    private func addButton(_ title: String, control: TouchOverlayControl,
                           onPress: @escaping (Bool) -> Void) {
        // baseDiameter is the starting size only; layoutSubviews resizes it
        // per device via TouchOverlayLayout.
        let button = OverlayButton(title: title, size: control.baseDiameter, onPress: onPress)
        button.accessibilityIdentifier = control.rawValue
        buttons.append(button)
        addSubview(button)
    }

    /// Height of the strip the debug HUD claims along the top edge (only
    /// when the "Show Debug Info" toggle is on).
    private static let debugHUDStripHeight: CGFloat = 22

    /// Live geometry for the current bounds. Recomputed rather than cached:
    /// it is a handful of arithmetic ops, and iPadOS windowed multitasking
    /// resizes the window continuously during a drag, so a cached copy would
    /// be stale exactly when it matters.
    private var layout: TouchOverlayLayout {
        TouchOverlayLayout(bounds: bounds, safeAreaInsets: safeAreaInsets,
                           hudReserve: debugHUDEnabled ? Self.debugHUDStripHeight : 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = safeAreaInsets
        let b = bounds
        if let debugHUDLabel {
            debugHUDLabel.frame = CGRect(x: b.minX + inset.left, y: b.minY + inset.top,
                                         width: b.width - inset.left - inset.right,
                                         height: Self.debugHUDStripHeight)
        }
        // Position *and* size come from TouchOverlayLayout -- see its doc
        // comment for the arrangement and why the offsets scale. Buttons the
        // layout does not know about are left alone rather than stacked at
        // the origin.
        let layout = self.layout
        for button in buttons {
            guard let id = button.accessibilityIdentifier,
                  let control = TouchOverlayControl(rawValue: id) else { continue }
            button.frame = layout.frame(for: control)
        }
    }

    /// Live routing decision for the current geometry. Recomputed per
    /// touch-begin for the same reason `layout` is: button frames follow the
    /// bounds, and iPadOS windowed multitasking resizes those continuously.
    /// The margin and the column split live on `TouchTrackRouter`, where they
    /// are covered by `WaddleTests`.
    private var trackRouter: TouchTrackRouter {
        TouchTrackRouter(
            overlayWidth: bounds.width,
            scheme: scheme,
            buttons: buttons.map {
                TouchOverlayButtonState(frame: $0.frame, isHidden: $0.isHidden)
            })
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
        // Built once for the whole batch: the button frames it reads cannot
        // change mid-loop, and which tracks are already owned is passed per
        // touch instead.
        let router = trackRouter
        for touch in touches {
            let point = touch.location(in: self)
            switch router.route(point,
                                stickTracking: stickTouch != nil,
                                turnTracking: turnTouch != nil) {
            case .stick:
                stickTouch = touch
                stickModel = TouchStickModel(center: point, radius: layout.stickRadius,
                                             deadZone: CGFloat(tuning.stickDeadZone))
                drawStick(at: point)
                stickEngagedMarker.isHidden = false
            case .turn:
                turnTouch = touch
                lastTurnX = point.x
                turnModel = TouchStickModel(center: point, radius: layout.stickRadius)
                drawTurnStick(at: point)
            case .ignore:
                // A near-miss on a button, or a region already owned by
                // another finger. Doing nothing is what a miss should do.
                break
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
            arcCenter: center, radius: layout.stickRadius, startAngle: 0,
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
            arcCenter: center, radius: layout.stickRadius, startAngle: 0,
            endAngle: .pi * 2, clockwise: true).cgPath
        moveKnob(turnKnob, to: center)
        turnBase.isHidden = false
        turnKnob.isHidden = false
    }

    private func moveKnob(_ knob: CAShapeLayer, to point: CGPoint) {
        knob.path = UIBezierPath(
            arcCenter: point, radius: layout.knobRadius, startAngle: 0,
            endAngle: .pi * 2, clockwise: true).cgPath
    }
}

/// A press-and-hold control (UIButton's tap gesture adds latency; Doom fire
/// must be press=down / release=up).
final class OverlayButton: UIView {
    private let onPress: (Bool) -> Void
    private let label = UILabel()

    /// Debug/test telemetry only (WADDLE_DEBUG_INPUT_COUNTS): how many
    /// press-downs have been delivered to any overlay button in this
    /// process. ContentView shows it post-session for the same reason it
    /// shows TouchGamepad.lastFireReleaseTriggerResidue -- the overlay is
    /// torn down the instant the session ends, so a UITest cannot read
    /// anything off it live. See
    /// TouchControlsTests.testCornerTapMissesCircularButton.
    static var debugPressCount = 0

    init(title: String, size: CGFloat, onPress: @escaping (Bool) -> Void) {
        self.onPress = onPress
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title

        backgroundColor = UIColor.white.withAlphaComponent(0.12)
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor

        label.frame = bounds
        label.text = title
        label.textColor = UIColor.white.withAlphaComponent(0.7)
        label.textAlignment = .center
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(label)
        // `size` is only the starting diameter: TouchOverlayLayout resizes
        // every button per device, so the round corner and the label size
        // are derived from the live bounds below rather than pinned here.
        applyDiameterDerivedStyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Corner radius and label size follow the frame, not the constructor
    /// argument. Without this a button resized by the layout (roughly 1.57x
    /// on a 13" iPad, smaller than 1x in a small iPadOS window) would keep
    /// its original 42pt corner radius on a 132pt box — a square with dented
    /// corners — and a phone-sized label rattling around inside it.
    override func layoutSubviews() {
        super.layoutSubviews()
        applyDiameterDerivedStyle()
    }

    private func applyDiameterDerivedStyle() {
        // min(): the same inscribed-circle rule `point(inside:)` uses, so the
        // drawn shape and the hit area cannot disagree on a non-square frame.
        let diameter = min(bounds.width, bounds.height)
        layer.cornerRadius = diameter / 2
        label.font = .systemFont(ofSize: diameter * 0.28, weight: .bold)
    }

    /// The control is drawn as a circle (`cornerRadius = size / 2` above) but
    /// is a square `UIView`, and UIKit's default hit-testing accepts the whole
    /// frame -- so the four corners, which are visually off the button, used
    /// to fire it anyway. Restricting delivery to the drawn circle makes a
    /// corner touch miss entirely (`hitTest` returns nil, so touchesBegan and
    /// touchesEnded never fire for it) and fall through to the overlay
    /// underneath, exactly as it would for a genuinely circular control.
    ///
    /// `min(width, height)` rather than `width`: it is the same value the
    /// corner radius is derived from for a square frame, and it degrades to
    /// the inscribed circle rather than an overshooting one if the button is
    /// ever laid out non-square.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let radius = min(bounds.width, bounds.height) / 2
        let dx = point.x - bounds.midX
        let dy = point.y - bounds.midY
        return dx * dx + dy * dy <= radius * radius
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        Self.debugPressCount += 1
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
