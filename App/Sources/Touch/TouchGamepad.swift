import CoreGraphics
import WoofEngine

/// SDL gamepad button/axis ordinals, verified against the pinned SDL3
/// (Vendor/src/SDL/include/SDL3/SDL_gamepad.h, `SDL_GamepadButton` /
/// `SDL_GamepadAxis` enums) in Task 3 Step 1. SOUTH and LEFTX are the first
/// non-negative members of their respective plain C enums (INVALID = -1
/// precedes both), so ordinals start at 0 as assumed.
enum TouchButton: Int32 {
    case south = 0           // SDL_GAMEPAD_BUTTON_SOUTH  -> fire (Woof default)
    case east = 1            // SDL_GAMEPAD_BUTTON_EAST   -> use
    case back = 4            // SDL_GAMEPAD_BUTTON_BACK   -> automap
    case start = 6           // SDL_GAMEPAD_BUTTON_START  -> menu
    case leftShoulder = 9    // SDL_GAMEPAD_BUTTON_LEFT_SHOULDER  -> prev weapon
    case rightShoulder = 10  // SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER -> next weapon
}

private let sdlAxisLeftX: Int32 = 0   // SDL_GAMEPAD_AXIS_LEFTX
private let sdlAxisLeftY: Int32 = 1   // SDL_GAMEPAD_AXIS_LEFTY

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

    func setMovement(x: Float, y: Float) {
        WoofIOS_SetTouchAxis(sdlAxisLeftX, x)
        WoofIOS_SetTouchAxis(sdlAxisLeftY, y)
    }

    func setButton(_ button: TouchButton, down: Bool) {
        WoofIOS_SetTouchButton(button.rawValue, down)
    }

    func turn(byPoints dx: CGFloat) {
        WoofIOS_InjectRelativeTurn(Float(dx) * turnSensitivity)
    }
}
