import Foundation

/// Which weapon selector the touch overlay installs: the half-ring (the
/// current official Doom iOS app's selector, the default) or the 3x3 grid
/// (the predecessor app's). One global setting, read once when the overlay
/// is installed, like `TouchControlScheme`; a change applies to the next
/// session. See docs/superpowers/specs/2026-11-19-weapon-select-ring-design.md.
enum WeaponSelectorStyle: String, CaseIterable {
    case ring
    case grid

    static let defaultStyle: WeaponSelectorStyle = .ring
    static let userDefaultsKey = "weaponSelectorStyle"
    /// DEBUG-only launch override (`ring` / `grid`), so a UI test can pin the
    /// style without depending on @AppStorage timing; the same test-seam
    /// pattern as `WADDLE_TOUCH_SCHEME`. Never set outside a test launch.
    static let environmentKey = "WADDLE_WEAPON_SELECTOR"

    /// The persisted style, or `defaultStyle` when unset or unrecognized. A
    /// SwiftUI view should use `@AppStorage(WeaponSelectorStyle.userDefaultsKey)`
    /// so the picker and this read stay on the same key. `environment` is a
    /// parameter only so the override can be tested.
    static func current(defaults: UserDefaults = .standard,
                        environment: [String: String] = ProcessInfo.processInfo.environment)
        -> WeaponSelectorStyle {
        #if DEBUG
        if let raw = environment[environmentKey], let style = WeaponSelectorStyle(rawValue: raw) {
            return style
        }
        #endif
        guard let raw = defaults.string(forKey: userDefaultsKey) else { return defaultStyle }
        return WeaponSelectorStyle(rawValue: raw) ?? defaultStyle
    }

    var displayLabel: String {
        switch self {
        case .ring: return "Ring"
        case .grid: return "Grid"
        }
    }
}
