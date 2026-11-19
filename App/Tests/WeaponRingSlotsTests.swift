import XCTest
@testable import Waddle

/// The ring's seven slots and which weapon a pick of each would give. Engine
/// weapon numbers: fist 0, pistol 1, shotgun 2, chaingun 3, rockets 4,
/// plasma 5, BFG 6, chainsaw 7, super shotgun 8.
final class WeaponRingSlotsTests: XCTestCase {
    private func states(owned: Set<Int>) -> [WeaponSlotState] {
        (0..<9).map { WeaponSlotState(owned: owned.contains($0), canFire: true) }
    }

    func testTable() {
        XCTAssertEqual(WeaponRingSlots.count, 7)
        XCTAssertEqual(WeaponRingSlots.weapons, [[0, 7], [1], [2, 8], [3], [4], [5], [6]])
    }

    func testSlotOfEveryWeapon() {
        let expected = [0: 0, 7: 0, 1: 1, 2: 2, 8: 2, 3: 3, 4: 4, 5: 5, 6: 6]
        for (weapon, slot) in expected {
            XCTAssertEqual(WeaponRingSlots.slot(of: weapon), slot, "weapon \(weapon)")
        }
        XCTAssertNil(WeaponRingSlots.slot(of: -1))
        XCTAssertNil(WeaponRingSlots.slot(of: 9))
    }

    func testSingleWeaponSlotResolvesToItsWeaponOnlyWhenOwned() {
        let all = states(owned: Set(0..<9))
        let none = states(owned: [])
        for (slot, weapon) in [(1, 1), (3, 3), (4, 4), (5, 5), (6, 6)] {
            XCTAssertEqual(WeaponRingSlots.resolve(slot, slots: all, selected: nil), weapon, "slot \(slot)")
            XCTAssertNil(WeaponRingSlots.resolve(slot, slots: none, selected: nil), "slot \(slot)")
        }
    }

    func testSharedSlotWithNeitherOwnedResolvesToNone() {
        let none = states(owned: [1])
        XCTAssertNil(WeaponRingSlots.resolve(0, slots: none, selected: 1))
        XCTAssertNil(WeaponRingSlots.resolve(2, slots: none, selected: 1))
    }

    func testSharedSlotWithOneOwnedResolvesToThatOne() {
        XCTAssertEqual(WeaponRingSlots.resolve(0, slots: states(owned: [0, 1]), selected: 0), 0)
        XCTAssertEqual(WeaponRingSlots.resolve(0, slots: states(owned: [1, 7]), selected: 7), 7)
        XCTAssertEqual(WeaponRingSlots.resolve(2, slots: states(owned: [1, 2]), selected: 2), 2)
        XCTAssertEqual(WeaponRingSlots.resolve(2, slots: states(owned: [1, 8]), selected: 8), 8)
    }

    func testSharedSlotWithBothOwnedPrefersChainsawAndSuperShotgun() {
        let both = states(owned: [0, 1, 2, 7, 8])
        XCTAssertEqual(WeaponRingSlots.resolve(0, slots: both, selected: 1), 7)
        XCTAssertEqual(WeaponRingSlots.resolve(2, slots: both, selected: 1), 8)
        XCTAssertEqual(WeaponRingSlots.resolve(0, slots: both, selected: nil), 7)
        XCTAssertEqual(WeaponRingSlots.resolve(2, slots: both, selected: nil), 8)
    }

    /// Picking the slot again swaps: with the preferred partner up, the slot
    /// gives the other one, and with that one up it gives the preferred again.
    func testFistChainsawSwap() {
        let both = states(owned: [0, 1, 7])
        XCTAssertEqual(WeaponRingSlots.resolve(0, slots: both, selected: 7), 0)
        XCTAssertEqual(WeaponRingSlots.resolve(0, slots: both, selected: 0), 7)
    }

    func testShotgunSuperShotgunSwap() {
        let both = states(owned: [1, 2, 8])
        XCTAssertEqual(WeaponRingSlots.resolve(2, slots: both, selected: 8), 2)
        XCTAssertEqual(WeaponRingSlots.resolve(2, slots: both, selected: 2), 8)
    }

    func testResolveAll() {
        let s = states(owned: [0, 1, 2, 8])
        XCTAssertEqual(WeaponRingSlots.resolveAll(slots: s, selected: 8), [0, 1, 2, nil, nil, nil, nil])
    }

    func testDisplayWeaponFallsBackToTheFirstWeapon() {
        let s = states(owned: [1, 8])
        XCTAssertEqual(WeaponRingSlots.displayWeapon(0, slots: s, selected: 1), 0, "fist's silhouette")
        XCTAssertEqual(WeaponRingSlots.displayWeapon(2, slots: s, selected: 1), 8)
        XCTAssertEqual(WeaponRingSlots.displayWeapon(6, slots: s, selected: 1), 6)
    }

    /// A short or out-of-range table never crashes and resolves nothing.
    func testShortTableAndBadSlotResolveToNone() {
        XCTAssertNil(WeaponRingSlots.resolve(1, slots: [], selected: nil))
        XCTAssertNil(WeaponRingSlots.resolve(-1, slots: states(owned: Set(0..<9)), selected: nil))
        XCTAssertNil(WeaponRingSlots.resolve(7, slots: states(owned: Set(0..<9)), selected: nil))
        XCTAssertEqual(WeaponRingSlots.resolve(0, slots: Array(states(owned: [0, 7]).prefix(3)), selected: nil), 0,
                       "a chainsaw entry the table does not have is not owned")
    }
}
