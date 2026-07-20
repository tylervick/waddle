import CoreGraphics
import Foundation
import WoofEngine

/// SDL gamepad button/axis ordinals, verified against the pinned SDL3
/// (Vendor/src/SDL/include/SDL3/SDL_gamepad.h, `SDL_GamepadButton` /
/// `SDL_GamepadAxis` enums) in Task 3 Step 1. SOUTH and LEFTX are the first
/// non-negative members of their respective plain C enums (INVALID = -1
/// precedes both), so ordinals start at 0 as assumed.
///
/// Fixed against user feedback (on-device: FIRE/USE did nothing): Woof!'s
/// *default* gamepad bindings are `input_fire = GAMEPAD_RIGHT_TRIGGER`,
/// `input_use = GAMEPAD_SOUTH` (Engine/woof/src/m_input.c:654-658). We were
/// sending SOUTH for our FIRE button (which Woof reads as USE) and EAST for
/// USE (unbound by default, so it did nothing). SOUTH now drives USE; EAST
/// is unused. FIRE is handled separately below -- GAMEPAD_RIGHT_TRIGGER in
/// Woof's bindings is not a real SDL button at all, it's a *virtual* button
/// Woof synthesizes from the RIGHT_TRIGGER axis crossing a threshold
/// (TriggerToButton/TriggerToButtons, Engine/woof/src/i_input.c:106-138), so
/// it must be driven via the axis, not SetTouchButton.
///
/// Fixed again (second device-testing round: MAP did nothing): automap was
/// wired to BACK, which -- like the original FIRE/USE mixup -- was guessed,
/// not verified. `GAMEPAD_BACK` has no entry anywhere in m_input.c's
/// `default_inputs` table (it's only ever a display-label string, never an
/// action binding), so it silently did nothing. Woof's default is
/// `input_map = GAMEPAD_NORTH` (m_input.c:689-690). NORTH now drives MAP;
/// BACK is unused (same "guessed wrong" story as EAST). See the wiring
/// audit table in TouchOverlayView (where every button is actually wired)
/// for the full per-control citation list -- check it before adding a new
/// button instead of guessing.
enum TouchButton: Int32 {
    case south = 0           // SDL_GAMEPAD_BUTTON_SOUTH  -> use (Woof default)
    case east = 1            // SDL_GAMEPAD_BUTTON_EAST   -> unused (no Woof default binding)
    case north = 3           // SDL_GAMEPAD_BUTTON_NORTH  -> automap (Woof default)
    case back = 4            // SDL_GAMEPAD_BUTTON_BACK   -> unused (no Woof default binding)
    case start = 6           // SDL_GAMEPAD_BUTTON_START  -> menu
    case leftShoulder = 9    // SDL_GAMEPAD_BUTTON_LEFT_SHOULDER  -> prev weapon
    case rightShoulder = 10  // SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER -> next weapon
}

private let sdlAxisLeftX: Int32 = 0        // SDL_GAMEPAD_AXIS_LEFTX
private let sdlAxisLeftY: Int32 = 1        // SDL_GAMEPAD_AXIS_LEFTY
private let sdlAxisRightX: Int32 = 2       // SDL_GAMEPAD_AXIS_RIGHTX (Vendor/src/SDL/include/SDL3/SDL_gamepad.h:227) -- Woof's turn axis in "classic" scheme
private let sdlAxisRightTrigger: Int32 = 5 // SDL_GAMEPAD_AXIS_RIGHT_TRIGGER (Vendor/src/SDL/include/SDL3/SDL_gamepad.h:230) -- drives Woof's synthesized fire button

@MainActor
final class TouchGamepad {
    private(set) var isAttached = false

    /// Debug/test telemetry only (BOOMBOX_DEBUG_INPUT_COUNTS): the
    /// gamepad-layer RIGHT_TRIGGER value sampled ~0.3s after the most
    /// recent FIRE release. WoofIOS_DebugTriggerValue() reads live engine
    /// state that's torn down (and returns -1) the instant the session
    /// ends, so a UITest can't read it fresh post-session -- ContentView
    /// shows this cached static instead. nil until FIRE has been released
    /// at least once in this process.
    static var lastFireReleaseTriggerResidue: Float?

    /// Points-to-mouse-counts calibration for `turn(byPoints:)`. The value
    /// this produces is further scaled by Woof's own mouse-sensitivity
    /// pipeline (default mouse_sens_angle ~= 16) once it reaches the engine,
    /// so this is only the app-side knob, not the whole feel. 4.0 is the
    /// play-tested value from woof-ios (TouchControlsView.lookSensitivity),
    /// which feeds the same drag-delta -> mouse-motion path into the same
    /// engine mouse pipeline.
    var turnSensitivity: Float = 4.0

    /// User tuning (turnSpeed/moveSensitivity multipliers), set by
    /// OverlayPresenter from persisted UserDefaults at overlay-install time.
    var tuning: TouchTuning = .default

    @discardableResult
    func attachIfPossible() -> Bool {
        isAttached = WoofIOS_AttachTouchGamepad()
        return isAttached
    }

    func detach() {
        WoofIOS_DetachTouchGamepad()
        isAttached = false
    }

    /// Routes a stick's raw (x, y) deflection to SDL axes per the active
    /// control scheme (see TouchControlScheme.axisMapping) and pushes all
    /// three movement-relevant axes every call, so switching schemes never
    /// leaves a stale nonzero value on an axis the new scheme doesn't drive.
    func setMovement(x: Float, y: Float, scheme: TouchControlScheme) {
        let mapping = tuning.apply(to: scheme.axisMapping(stickX: x, stickY: y))
        WoofIOS_SetTouchAxis(sdlAxisLeftX, mapping.leftX)
        WoofIOS_SetTouchAxis(sdlAxisLeftY, mapping.leftY)
        WoofIOS_SetTouchAxis(sdlAxisRightX, mapping.rightX)
    }

    func setButton(_ button: TouchButton, down: Bool) {
        WoofIOS_SetTouchButton(button.rawValue, down)
    }

    /// Drives Woof!'s fire input, which reads the RIGHT_TRIGGER axis rather
    /// than a real SDL button (see the TouchButton doc comment above).
    func setFireTrigger(down: Bool) {
        WoofIOS_SetTouchTrigger(sdlAxisRightTrigger, down)
        if !down {
            sampleTriggerResidueAfterRelease()
        }
    }

    /// Debug/test telemetry only -- see `lastFireReleaseTriggerResidue`.
    /// Sampled asynchronously rather than immediately: SDL processes the
    /// virtual-axis write and re-derives the gamepad-layer value on its own
    /// schedule, so reading back synchronously could observe a stale value.
    /// asyncAfter still lands mid-session (SDL pumps the main run loop
    /// while WoofIOS_Run blocks, same reasoning as OverlayPresenter's poll
    /// timer), well within the autoquit window any UITest exercising this
    /// arms for.
    private func sampleTriggerResidueAfterRelease() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Self.lastFireReleaseTriggerResidue = WoofIOS_DebugTriggerValue()
        }
    }

    func turn(byPoints dx: CGFloat) {
        WoofIOS_InjectRelativeTurn(Float(dx) * tuning.scaledTurnSensitivity(base: turnSensitivity))
    }
}
