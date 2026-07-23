import Foundation

/// The engine's current text-entry context, mirrored from
/// `WoofIOS_GetTextInputContext()`. Drives when the soft keyboard is allowed
/// to appear (see `KeyboardGate`).
enum TextInputContext: Equatable {
    case none       // title, ordinary menus, intermission/finale, demo
    case gameplay   // live level, no menu, not paused -> cheats
    case saveName   // menu save-name field is capturing input
}

/// What a context poll should do with the keyboard right now.
enum KeyboardCommand: Equatable {
    case none, present, dismiss
}

/// Pure decision logic for when the soft keyboard may appear or must
/// disappear, given the engine's text-input context. Free of UIKit so it is
/// unit-testable in isolation (see KeyboardGateTests).
enum KeyboardGate {
    /// A summon gesture (four-finger tap) presents the keyboard only during
    /// live gameplay; in every other context the tap is ignored, so it can
    /// never pop up at the title screen or in ordinary menus.
    static func shouldPresentOnTap(context: TextInputContext) -> Bool {
        context == .gameplay
    }

    /// Run periodically: auto-present for save-name entry, auto-dismiss if
    /// the keyboard is visible but the engine has left a text context
    /// (player died, level ended, menu opened). Gameplay presentation is
    /// tap-driven, so a visible gameplay keyboard is left as-is.
    static func pollCommand(context: TextInputContext,
                            isVisible: Bool) -> KeyboardCommand {
        switch context {
        case .saveName:
            return isVisible ? .none : .present
        case .none:
            return isVisible ? .dismiss : .none
        case .gameplay:
            return .none
        }
    }
}
