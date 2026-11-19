import XCTest
@testable import Waddle

/// Which weapon selector the overlay installs: the ring by default, the grid
/// behind a setting, and a DEBUG-only launch override for UI tests.
final class WeaponSelectorStyleTests: XCTestCase {

    func testDefaultIsRing() {
        XCTAssertEqual(WeaponSelectorStyle.defaultStyle, .ring)
    }

    func testKeysAreStable() {
        XCTAssertEqual(WeaponSelectorStyle.userDefaultsKey, "weaponSelectorStyle")
        XCTAssertEqual(WeaponSelectorStyle.environmentKey, "WADDLE_WEAPON_SELECTOR")
        XCTAssertEqual(WeaponSelectorStyle.ring.rawValue, "ring")
        XCTAssertEqual(WeaponSelectorStyle.grid.rawValue, "grid")
        XCTAssertEqual(WeaponSelectorStyle.allCases, [.ring, .grid])
    }

    func testCurrentFallsBackToRingWhenUnset() {
        withEmptyDefaults { defaults in
            XCTAssertEqual(WeaponSelectorStyle.current(defaults: defaults, environment: [:]), .ring)
        }
    }

    func testCurrentFallsBackToRingWhenUnrecognized() {
        withEmptyDefaults { defaults in
            defaults.set("wheel", forKey: WeaponSelectorStyle.userDefaultsKey)
            XCTAssertEqual(WeaponSelectorStyle.current(defaults: defaults, environment: [:]), .ring)
        }
    }

    func testCurrentReadsPersistedGrid() {
        withEmptyDefaults { defaults in
            defaults.set(WeaponSelectorStyle.grid.rawValue, forKey: WeaponSelectorStyle.userDefaultsKey)
            XCTAssertEqual(WeaponSelectorStyle.current(defaults: defaults, environment: [:]), .grid)
        }
    }

    func testCurrentReadsPersistedRing() {
        withEmptyDefaults { defaults in
            defaults.set(WeaponSelectorStyle.ring.rawValue, forKey: WeaponSelectorStyle.userDefaultsKey)
            XCTAssertEqual(WeaponSelectorStyle.current(defaults: defaults, environment: [:]), .ring)
        }
    }

    #if DEBUG
    func testEnvironmentOverrideWinsOverPersistedValue() {
        withEmptyDefaults { defaults in
            defaults.set(WeaponSelectorStyle.ring.rawValue, forKey: WeaponSelectorStyle.userDefaultsKey)
            XCTAssertEqual(WeaponSelectorStyle.current(defaults: defaults,
                                                       environment: ["WADDLE_WEAPON_SELECTOR": "grid"]), .grid)
            defaults.set(WeaponSelectorStyle.grid.rawValue, forKey: WeaponSelectorStyle.userDefaultsKey)
            XCTAssertEqual(WeaponSelectorStyle.current(defaults: defaults,
                                                       environment: ["WADDLE_WEAPON_SELECTOR": "ring"]), .ring)
        }
    }

    func testUnrecognizedEnvironmentOverrideIsIgnored() {
        withEmptyDefaults { defaults in
            defaults.set(WeaponSelectorStyle.grid.rawValue, forKey: WeaponSelectorStyle.userDefaultsKey)
            XCTAssertEqual(WeaponSelectorStyle.current(defaults: defaults,
                                                       environment: ["WADDLE_WEAPON_SELECTOR": "wheel"]), .grid)
        }
    }
    #endif

    func testDisplayLabels() {
        XCTAssertEqual(WeaponSelectorStyle.ring.displayLabel, "Ring")
        XCTAssertEqual(WeaponSelectorStyle.grid.displayLabel, "Grid")
    }

    // MARK: Helpers

    /// A throwaway, uniquely named suite, removed with `defer` for the reason
    /// `TouchControlSchemeTests` gives.
    private func withEmptyDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "WeaponSelectorStyleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
