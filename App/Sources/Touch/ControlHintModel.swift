import Foundation

/// Whether the overlay shows its control hints: one global setting, read
/// once when the overlay is installed, like `WeaponSelectorStyle`; a change
/// applies to the next session. On unless the player turned it off.
enum ControlHintsSetting {
    static let userDefaultsKey = "showControlHints"
    static let defaultValue = true
    /// DEBUG-only launch override (`1` / `0`), so a UI test can pin the
    /// setting whatever the app container has stored; the same test-seam
    /// pattern as `WADDLE_WEAPON_SELECTOR`. Never set outside a test launch.
    static let environmentKey = "WADDLE_CONTROL_HINTS"

    /// The persisted setting, or `defaultValue` when it was never written. A
    /// SwiftUI view should use `@AppStorage(ControlHintsSetting.userDefaultsKey)`
    /// so the toggle and this read stay on the same key. `environment` is a
    /// parameter only so the override can be tested.
    static func current(defaults: UserDefaults = .standard,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        #if DEBUG
        switch environment[environmentKey] {
        case "1": return true
        case "0": return false
        default: break
        }
        #endif
        return defaults.object(forKey: userDefaultsKey) as? Bool ?? defaultValue
    }
}

/// When the overlay's control hints are on screen (issue #392). The weapon
/// selector opens from a zone nothing draws, so after `idleDelay` seconds
/// without a touch the overlay names it, and in the Modern scheme names the
/// stick side and the drag-turn side with it.
///
/// Pure, in the shape of `WeaponRingModel` and `MenuTouchRouter`: time and
/// events in, visible or hidden out, so `WaddleTests` pins the rule without
/// a simulator session. `TouchOverlayView` feeds it and shows what it says.
///
/// The count runs only while the selector could open and nothing is held.
/// A touch-down clears it, and so does every tick on which a finger is
/// still down or the selector cannot open (a menu, a prompt, the automap,
/// attract mode, the soft keyboard, the selector itself). It starts again
/// at the first tick that finds the overlay idle, so the hint follows four
/// whole idle seconds: never fewer because a finger lifted, or a menu
/// closed, part-way between two ticks.
struct ControlHintModel: Equatable {
    /// Seconds without a touch before the hints appear. A default to tune on
    /// a device, like the copy (issue #392's provenance).
    static let idleDelay: TimeInterval = 4

    /// What is on screen. `moveAndAim` is never true without `weapons`.
    struct Hints: Equatable {
        var weapons: Bool
        var moveAndAim: Bool

        static let hidden = Hints(weapons: false, moveAndAim: false)
    }

    /// The Show Control Hints setting. Off means never visible.
    let enabled: Bool
    let scheme: TouchControlScheme
    private(set) var hints = Hints.hidden
    /// The first tick of the current idle stretch; nil when the last thing
    /// seen was a touch-down, a held finger or a selector that cannot open.
    private var idleSince: TimeInterval?

    init(enabled: Bool, scheme: TouchControlScheme) {
        self.enabled = enabled
        self.scheme = scheme
    }

    /// A finger came down anywhere on the overlay, a button included: the
    /// hints go at once, and the count starts again at the next idle tick.
    mutating func touchDown() {
        idleSince = nil
        hints = .hidden
    }

    /// The overlay's poll. `canOpen` is whether the weapon selector could
    /// open right now; `touching` is whether any finger is still down.
    mutating func tick(at now: TimeInterval, canOpen: Bool, touching: Bool) {
        guard enabled, canOpen, !touching else {
            idleSince = nil
            hints = .hidden
            return
        }
        let since = idleSince ?? now
        idleSince = since
        let visible = now - since >= Self.idleDelay
        // Move and Aim name the two halves of a twin-stick layout. Classic
        // has no aim side to label, so it shows Weapons alone.
        hints = Hints(weapons: visible, moveAndAim: visible && scheme.usesDragTurn)
    }
}
