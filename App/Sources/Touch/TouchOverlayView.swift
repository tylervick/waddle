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
    /// The player's button positions (issue #115), read once at install
    /// like `tuning`; applied by `layout`.
    private let layoutOverrides: TouchOverlayLayoutOverrides

    private var stickTouch: UITouch?
    // Placeholders only: both are rebuilt at the touch point, with the
    // device-scaled `layout.stickRadius`, on every touch-begin.
    private var stickModel = TouchStickModel(center: .zero, radius: 60)
    private var turnTouch: UITouch?
    /// The finger driving the engine menu's pointer (`MenuTouchRouter`).
    private var menuTouch: UITouch?
    /// A finger that landed in the stick column while a menu was up, and
    /// where: the stick if it travels, a tap if it lifts in place.
    private var pendingMenuTouch: (touch: UITouch, start: CGPoint)?
    private let menuRouter = MenuTouchRouter()
    /// Answer an engine Y/N prompt; shown only while one is on screen.
    private let promptNoButton: OverlayButton
    private let promptYesButton: OverlayButton
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

    // Automap gestures (issue #113). While the engine's automap is up, free-
    // area touches pan (one finger) and zoom (two) it instead of starting
    // stick or turn tracks. The translator is pure; this owns the touches,
    // their previous points, the keys currently held, and the idle timer
    // that releases them when the fingers stop moving (the engine keeps
    // panning while a key is down, so "stopped" must release).
    private var automapTouches: [UITouch] = []
    private var automapLastPoints: [CGPoint] = []
    private var automapHeldKeys: AutomapKeys = []
    private var automapIdleTimer: Timer?
    private let automapTranslator = AutomapGestureTranslator()

    init(gamepad: TouchGamepad, scheme: TouchControlScheme,
         tuning: TouchTuning, debugHUDEnabled: Bool,
         layoutOverrides: TouchOverlayLayoutOverrides = .none) {
        self.gamepad = gamepad
        self.scheme = scheme
        self.tuning = tuning
        self.debugHUDEnabled = debugHUDEnabled
        self.layoutOverrides = layoutOverrides
        self.keyboard = TouchKeyboard(injector: gamepad)
        // Created here and never added to `buttons`: they are not a
        // `TouchOverlayControl` (the layout editor must not offer them), and
        // they answer on the press, not the release, because a prompt needs
        // one keystroke and OverlayPressTiming's held release is for the pad.
        let answer = { (yes: Bool) -> (Bool) -> Void in
            { down in if down { gamepad.answerPrompt(yes: yes) } }
        }
        promptNoButton = OverlayButton(title: "No", size: TouchOverlayLayout.promptButtonBaseDiameter,
                                       onPress: answer(false))
        promptNoButton.accessibilityIdentifier = "promptNoButton"
        promptYesButton = OverlayButton(title: "Yes", size: TouchOverlayLayout.promptButtonBaseDiameter,
                                        onPress: answer(true))
        promptYesButton.accessibilityIdentifier = "promptYesButton"
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        accessibilityIdentifier = "touchOverlay"
        for button in [promptNoButton, promptYesButton] {
            button.isHidden = true
            addSubview(button)
        }

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
            label.font = Self.debugHUDFont
            label.textColor = UIColor.white.withAlphaComponent(0.6)
            label.backgroundColor = UIColor.black.withAlphaComponent(0.3)
            label.textAlignment = .left
            // Wrap rather than truncate: on a phone the strip is longer than
            // one line, and a Revyl device run reads its tail (the pad= ...
            // menu= segment) off a screenshot. An ellipsis there is the one
            // thing the strip must never show.
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
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
        automapIdleTimer?.invalidate()
        automapIdleTimer = nil
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
            self?.dropAutomapGestureIfMapClosed()
            self?.updatePromptButtons()
            self?.dropMenuTouchesIfMenuClosed()
        }
        RunLoop.main.add(timer, forMode: .common)
        menuPolicyTimer = timer
        updateAutomapAvailability()
    }

    /// The map can close under a finger (MAP tapped with the other hand, or
    /// the level ending); nothing must stay held for a map that is gone.
    private func dropAutomapGestureIfMapClosed() {
        if !automapTouches.isEmpty, !WoofIOS_IsAutomapActive() {
            automapTouches.removeAll()
            automapLastPoints.removeAll()
            holdAutomapKeys([])
        }
    }

    private func updateAutomapAvailability() {
        let hideForMenu = WoofIOS_IsMenuActive()
        buttons.first { $0.accessibilityIdentifier == "automapButton" }?.isHidden = hideForMenu
    }

    /// The Yes/No pair appears with an engine prompt and leaves with it.
    /// The engine side also gates the answer itself, so a press that lands
    /// in the poll's 0.25 s window after the prompt closed is dropped there.
    private func updatePromptButtons() {
        let showing = gamepad.isMenuMessageShowing
        promptNoButton.isHidden = !showing
        promptYesButton.isHidden = !showing
    }

    /// A menu can close under a finger (the tapped item closed it, or the
    /// app was backgrounded). Forget the finger; the engine side posts the
    /// release for a press that was posted, so nothing stays held.
    private func dropMenuTouchesIfMenuClosed() {
        guard !WoofIOS_IsMenuActive() else { return }
        if menuTouch != nil {
            menuTouch = nil
            gamepad.menuTap(down: false)
        }
        pendingMenuTouch = nil
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
        // The second line is the engine's own state: first its window size
        // (WoofIOS_DebugWindowState; the landscape test in TouchControlsTests
        // reads it), then where the game is (WoofIOS_DebugGameState: level or
        // title, the -loadgame argument, leveltime; BackgroundSuspendTests
        // reads it), then what the engine
        // sees of this overlay's input (WoofIOS_DebugInputState): which
        // gamepad it has open and whether that is our virtual pad, button
        // events it has processed, and the menu cursor.
        // DebugHUDInputTelemetryTests parses that segment; a Revyl
        // device run reads it off a screenshot. Last, the touch-menu state
        // (WoofIOS_DebugMenuState: current menu, prompt flag, pointer
        // counters, item centres), which TouchMenuTests reads.
        debugHUDLabel?.text = String(
            format: "build %@ (%@) · %@ · events %d · trigger %.2f · turn %.2f · dz %.2f · move %.2f\n%@ · %@ · %@ · %@",
            BuildInfo.commit, BuildInfo.branch, scheme == .classic ? "classic" : "modern",
            WoofIOS_DebugTouchEventCount(), trigger,
            tuning.turnSpeed, tuning.stickDeadZone, tuning.moveSensitivity,
            String(cString: WoofIOS_DebugWindowState()),
            String(cString: WoofIOS_DebugGameState()),
            String(cString: WoofIOS_DebugInputState()),
            String(cString: WoofIOS_DebugMenuState()))
        // The line count can change with the text (a longer pad name, a
        // menu item), and the frame and the buttons below it follow it.
        if let debugHUDLabel, debugHUDLabel.frame.height != debugHUDStripHeight {
            setNeedsLayout()
        }
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

    static let debugHUDFont: UIFont = .monospacedSystemFont(ofSize: 11, weight: .regular)

    /// The least the strip claims along the top edge (only when the "Show
    /// Debug Info" toggle is on): four lines of the font, what the wrapped
    /// strip needed at phone width before the second line grew.
    static let debugHUDMinimumStripHeight: CGFloat = 60

    /// The height the strip needs for `text` at `width`: what the wrapped
    /// label measures, never less than the minimum. Measured, not fixed: a
    /// fixed frame clipped the strip's tail (`… ab= mv= menu=`) on an iPhone
    /// 17 Pro Max in portrait once the `gs=` segment joined the second line
    /// (issue #111), and the tail is the part a Revyl device run reads off
    /// a screenshot. `DebugHUDStripHeightTests` pins it.
    static func debugHUDStripHeight(for text: String, width: CGFloat) -> CGFloat {
        let label = UILabel()
        label.font = debugHUDFont
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.text = text
        let fitted = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return max(debugHUDMinimumStripHeight, ceil(fitted))
    }

    /// The strip's current height, from its current text and the width the
    /// safe area leaves it.
    private var debugHUDStripHeight: CGFloat {
        guard let debugHUDLabel else { return 0 }
        let inset = safeAreaInsets
        return Self.debugHUDStripHeight(for: debugHUDLabel.text ?? "",
                                        width: bounds.width - inset.left - inset.right)
    }

    /// Live geometry for the current bounds. Recomputed rather than cached:
    /// it is a handful of arithmetic ops, and iPadOS windowed multitasking
    /// resizes the window continuously during a drag, so a cached copy would
    /// be stale exactly when it matters.
    private var layout: TouchOverlayLayout {
        TouchOverlayLayout(bounds: bounds, safeAreaInsets: safeAreaInsets,
                           hudReserve: debugHUDEnabled ? debugHUDStripHeight : 0,
                           overrides: layoutOverrides)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = safeAreaInsets
        let b = bounds
        if let debugHUDLabel {
            debugHUDLabel.frame = CGRect(x: b.minX + inset.left, y: b.minY + inset.top,
                                         width: b.width - inset.left - inset.right,
                                         height: debugHUDStripHeight)
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
        let prompt = layout.promptButtonFrames()
        promptNoButton.frame = prompt.no
        promptYesButton.frame = prompt.yes
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
        let automapUp = WoofIOS_IsAutomapActive()
        let menuUp = WoofIOS_IsMenuActive()
        for touch in touches {
            let point = touch.location(in: self)
            let route = router.route(point, stickTracking: stickTouch != nil,
                                     turnTracking: turnTouch != nil)
            switch menuRouter.began(menuActive: menuUp, trackRoute: route,
                                    nearButton: router.isNearButton(point),
                                    pointerOwned: menuTouch != nil) {
            case .pointer:
                // Position first, then the press: the engine checks a press
                // against the item the latest position highlighted.
                menuTouch = touch
                gamepad.menuPointer(at: point)
                gamepad.menuTap(down: true)
                continue
            case .pending:
                pendingMenuTouch = (touch, point)
                continue
            case .ignore:
                continue
            case .passThrough:
                break
            }
            if automapUp {
                // Buttons keep their near-miss cushion; everything else is
                // the map's. Up to two fingers: a third is ignored.
                if router.isNearButton(point) || automapTouches.count >= 2 { continue }
                automapTouches.append(touch)
                automapLastPoints.append(point)
                continue
            }
            switch route {
            case .stick:
                beginStick(touch, at: point)
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

    /// Start the movement stick under `touch` at `point`: on touch-down in
    /// the stick column, or when a pending menu touch travels far enough.
    private func beginStick(_ touch: UITouch, at point: CGPoint) {
        stickTouch = touch
        stickModel = TouchStickModel(center: point, radius: layout.stickRadius,
                                     deadZone: CGFloat(tuning.stickDeadZone))
        drawStick(at: point)
        stickEngagedMarker.isHidden = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if keyboardActive { return }
        if !automapTouches.isEmpty, touches.contains(where: { automapTouches.contains($0) }) {
            moveAutomap()
            return
        }
        for touch in touches {
            let point = touch.location(in: self)
            if touch == menuTouch {
                gamepad.menuPointer(at: point)
            } else if let pending = pendingMenuTouch, touch == pending.touch {
                if menuRouter.pendingBecameStick(from: pending.start, to: point) {
                    pendingMenuTouch = nil
                    beginStick(touch, at: pending.start)
                    let axes = stickModel.axes(for: point)
                    gamepad.setMovement(x: axes.x, y: axes.y, scheme: scheme)
                    moveKnob(stickKnob, to: stickModel.knobPosition(for: point))
                }
            } else if touch == stickTouch {
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
        if !automapTouches.isEmpty {
            for touch in touches {
                if let i = automapTouches.firstIndex(of: touch) {
                    automapTouches.remove(at: i)
                    automapLastPoints.remove(at: i)
                }
            }
            if automapTouches.count < 2 { holdAutomapKeys([]) } // a lifted finger ends the gesture
        }
        for touch in touches {
            if touch == menuTouch {
                menuTouch = nil
                gamepad.menuTap(down: false)
            } else if let pending = pendingMenuTouch, touch == pending.touch {
                pendingMenuTouch = nil
                let point = touch.location(in: self)
                if menuRouter.ended(pendingFrom: pending.start, at: point) == .tap {
                    gamepad.menuPointer(at: point)
                    gamepad.menuTap(down: true)
                    gamepad.menuTap(down: false)
                }
            } else if touch == stickTouch {
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

    // MARK: Automap gestures (issue #113)

    /// One event's worth of drag or pinch, from the tracked touches' current
    /// positions against their previous ones. O(1): two points, one byte of
    /// keys, no allocation that follows the map.
    private func moveAutomap() {
        let points = automapTouches.map { $0.location(in: self) }
        var keys: AutomapKeys = []
        if points.count == 1 {
            let delta = CGPoint(x: points[0].x - automapLastPoints[0].x,
                                y: points[0].y - automapLastPoints[0].y)
            keys = automapTranslator.keys(forDrag: delta)
        } else if points.count == 2 {
            let before = hypot(automapLastPoints[0].x - automapLastPoints[1].x,
                               automapLastPoints[0].y - automapLastPoints[1].y)
            let now = hypot(points[0].x - points[1].x, points[0].y - points[1].y)
            if before > 0 { keys = automapTranslator.keys(forPinchRatio: now / before) }
        }
        automapLastPoints = points
        holdAutomapKeys(keys)
        // The engine pans for as long as the key is down; a finger that stops
        // moving sends no more events, so release shortly after the last one.
        automapIdleTimer?.invalidate()
        let timer = Timer(timeInterval: 0.12, repeats: false) { [weak self] _ in
            self?.holdAutomapKeys([])
        }
        RunLoop.main.add(timer, forMode: .common)
        automapIdleTimer = timer
    }

    /// Diffs `keys` against what is held and injects only the edges, so
    /// every keydown gets exactly one keyup (a latched key would pan forever;
    /// see docs/learnings/soft-keyboard-keydown-keyup-pairing.md).
    private func holdAutomapKeys(_ keys: AutomapKeys) {
        if keys == automapHeldKeys { return }
        let released = automapHeldKeys.subtracting(keys)
        let pressed = keys.subtracting(automapHeldKeys)
        for code in released.engineKeyCodes { WoofIOS_InjectKey(code, false) }
        for code in pressed.engineKeyCodes { WoofIOS_InjectKey(code, true) }
        automapHeldKeys = keys
        if keys.isEmpty {
            automapIdleTimer?.invalidate()
            automapIdleTimer = nil
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
        // Direct interaction, not .button (issue #215): a .button element is
        // activated by VoiceOver with focus-then-double-tap, one control at a
        // time, and Doom needs simultaneous, sustained input -- strafe while
        // firing, hold forward while turning. .allowsDirectInteraction is the
        // trait Apple gives a control that must receive the user's touches
        // as touches (an on-screen piano, a drawing canvas), so VoiceOver
        // passes a touch on this circle straight to touchesBegan/Ended and
        // the press-and-hold machinery below works as it does without
        // VoiceOver. The label still lets a VoiceOver user find each control
        // by exploring. .button stays alongside it: it is what makes the
        // control announce as a button, and it is how XCUITest and Revyl
        // find the overlay (`app.buttons["fireButton"]`): measured with it
        // removed, every in-game UI test lost the overlay. Direct interaction
        // governs what a held finger does; .button only says what it is.
        // OverlayButtonAccessibilityTraitTests pins both.
        accessibilityTraits = [.button, .allowsDirectInteraction]
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

    // The engine samples the virtual pad only when it pumps events, so a
    // release is held back until the press has lasted long enough to be
    // seen (OverlayPressTiming). A new press arriving while a release is
    // still pending flushes that release first, so the engine sees two
    // distinct presses rather than one long one.
    private var timing = OverlayPressTiming.engineSafe
    // Tagged, so a delayed release fires only if it is still the current
    // one: a second tap flushes and replaces it, and the closure of the
    // replaced item must not release the new press.
    private var pendingRelease: (id: UUID, work: DispatchWorkItem)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        Self.debugPressCount += 1
        flushPendingRelease()
        backgroundColor = UIColor.white.withAlphaComponent(0.3)
        timing.pressed(at: ProcessInfo.processInfo.systemUptime)
        onPress(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        release()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        release()
    }

    private func release() {
        backgroundColor = UIColor.white.withAlphaComponent(0.12)
        let delay = timing.released(at: ProcessInfo.processInfo.systemUptime)
        guard delay > 0 else {
            onPress(false)
            return
        }
        let id = UUID()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingRelease?.id == id else { return }
            self.pendingRelease = nil
            self.onPress(false)
        }
        pendingRelease = (id, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func flushPendingRelease() {
        guard let pending = pendingRelease else { return }
        pending.work.cancel()
        pendingRelease = nil
        onPress(false)
    }
}
