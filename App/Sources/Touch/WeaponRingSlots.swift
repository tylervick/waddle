/// The weapon-select ring's seven slots, as in the official Doom iOS app:
/// fist/chainsaw and shotgun/super shotgun each share one. Pure, so
/// `WaddleTests` pins the table and the swap rule without the engine.
///
/// Weapons are engine numbers (`WoofIOS_WeaponSlot` order): fist 0, pistol 1,
/// shotgun 2, chaingun 3, rockets 4, plasma 5, BFG 6, chainsaw 7, super
/// shotgun 8.
enum WeaponRingSlots {
    static let count = 7

    /// Each slot's weapons. The first is the one whose silhouette an empty
    /// slot shows; in a shared slot the second is the preferred partner.
    static let weapons: [[Int]] = [[0, 7], [1], [2, 8], [3], [4], [5], [6]]

    /// The slot holding `weapon`, or nil for a number outside the nine.
    static func slot(of weapon: Int) -> Int? {
        weapons.firstIndex { $0.contains(weapon) }
    }

    /// The weapon a pick of `slot` would give, or nil when the slot has none
    /// owned. `slots` is the engine's nine owned/can-fire entries;
    /// `selected` the weapon up or pending.
    ///
    /// - A single-weapon slot gives that weapon if owned.
    /// - A shared slot with one owned gives that one.
    /// - A shared slot with both owned gives the preferred one (chainsaw,
    ///   super shotgun), unless that is the selected weapon: then the other,
    ///   so picking the slot again swaps.
    static func resolve(_ slot: Int, slots: [WeaponSlotState], selected: Int?) -> Int? {
        guard weapons.indices.contains(slot) else { return nil }
        let owned = weapons[slot].filter { slots.indices.contains($0) && slots[$0].owned }
        guard let first = owned.first else { return nil }
        guard owned.count == 2 else { return first }
        let preferred = owned[1]
        return preferred == selected ? owned[0] : preferred
    }

    static func resolveAll(slots: [WeaponSlotState], selected: Int?) -> [Int?] {
        (0..<count).map { resolve($0, slots: slots, selected: selected) }
    }

    /// What the slot shows: the resolved weapon, or for an empty slot the
    /// first weapon (drawn as a silhouette).
    static func displayWeapon(_ slot: Int, slots: [WeaponSlotState], selected: Int?) -> Int {
        resolve(slot, slots: slots, selected: selected) ?? weapons[slot][0]
    }
}
