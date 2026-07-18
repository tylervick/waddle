import CoreGraphics
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
enum TouchButton: Int32 {
    case south = 0           // SDL_GAMEPAD_BUTTON_SOUTH  -> use (Woof default)
    case east = 1            // SDL_GAMEPAD_BUTTON_EAST   -> unused (no Woof default binding)
    case back = 4            // SDL_GAMEPAD_BUTTON_BACK   -> automap
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

    /// Points-to-mouse-counts calibration for `turn(byPoints:)`. The value
    /// this produces is further scaled by Woof's own mouse-sensitivity
    /// pipeline (default mouse_sens_angle ~= 16) once it reaches the engine,
    /// so this is only the app-side knob, not the whole feel; expect this
    /// default to be retuned once we can play on a device.
    var turnSensitivity: Float = 1.5

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
        let mapping = scheme.axisMapping(stickX: x, stickY: y)
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
        WoofIOS_SetTouchAxis(sdlAxisRightTrigger, down ? 1.0 : 0.0)
    }

    func turn(byPoints dx: CGFloat) {
        WoofIOS_InjectRelativeTurn(Float(dx) * turnSensitivity)
    }
}
