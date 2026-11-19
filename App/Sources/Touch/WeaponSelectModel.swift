import Foundation

/// What the engine says about one weapon slot. Selectability reads `owned`
/// only: an owned weapon with no ammo is still pickable (the engine decides
/// what the switch does), and nothing about art may gate a pick.
struct WeaponSlotState: Equatable {
    var owned: Bool
    var canFire: Bool
}

enum WeaponCellAppearance: Equatable { case unowned, ready, empty, pressed }

/// The rules of the weapon-select grid: when it opens, which finger may pick,
/// when it closes. Pure, like `MenuTouchRouter`, so `WaddleTests` pins them
/// without UIKit or the engine. The caller does the hit-testing and passes in
/// the cell each touch is over; the model answers with effects to perform.
struct WeaponSelectModel {
    /// Cell labels in engine weapon order.
    static let names = ["fist", "pistol", "shotgun", "chaingun", "rockets",
                        "plasma", "BFG", "chainsaw", "dblshotgun"]

    enum Effect: Equatable { case releaseHeldInputs, select(Int), selectBest }

    private(set) var isOpen = false
    /// Always nine entries, in engine weapon order; starts all unowned.
    var slots = [WeaponSlotState](repeating: WeaponSlotState(owned: false, canFire: false),
                                  count: WeaponSelectModel.names.count)

    /// The one finger allowed to pick: the first that began inside a cell
    /// after opening. Fingers already down at open (a resting stick thumb)
    /// never begin here, so they can neither pick nor light a cell. This
    /// deliberately departs from the predecessor, which counted any lift and
    /// so picked a weapon when the movement thumb relaxed over the bottom row.
    private var tracked: AnyHashable?
    private var trackedCell: Int?

    /// A touch that began inside the hotspot. Closed + canOpen opens and
    /// releases everything held, so no gameplay input stays latched under the
    /// grid. Open closes and asks for the best weapon with ammo.
    mutating func hotspotTouchBegan(canOpen: Bool) -> [Effect] {
        if isOpen {
            close()
            return [.selectBest]
        }
        guard canOpen else { return [] }
        isOpen = true
        return [.releaseHeldInputs]
    }

    /// Any other touch that began while open; `cell` is where it landed. Only
    /// the first touch to land in a cell is tracked; later ones are ignored.
    mutating func touchBegan(_ id: AnyHashable, cell: Int?) {
        guard isOpen, tracked == nil, let cell else { return }
        tracked = id
        trackedCell = cell
    }

    mutating func touchMoved(_ id: AnyHashable, cell: Int?) {
        guard isOpen, id == tracked else { return }
        trackedCell = cell
    }

    /// The tracked touch picks the cell it lifts in, which may differ from
    /// where it began, if that cell is selectable. Lifting anywhere else picks
    /// nothing and the grid stays open, but the touch is spent so a later
    /// fresh touch can be tracked. Untracked touches never pick.
    mutating func touchEnded(_ id: AnyHashable, cell: Int?) -> [Effect] {
        guard isOpen, id == tracked else { return [] }
        forgetTouch()
        guard let cell, isSelectable(cell) else { return [] }
        close()
        return [.select(cell)]
    }

    mutating func touchCancelled(_ id: AnyHashable) {
        if id == tracked { forgetTouch() }
    }

    /// Polled: the engine's "grid may be open" answer. false (level ended,
    /// player died) closes and forgets the finger, so its eventual lift
    /// cannot pick.
    mutating func availabilityChanged(canOpen: Bool) {
        if !canOpen { close() }
    }

    /// Owned, nothing else. An index outside the nine slots is not selectable.
    func isSelectable(_ index: Int) -> Bool {
        slots.indices.contains(index) && slots[index].owned
    }

    func appearance(_ index: Int) -> WeaponCellAppearance {
        guard slots.indices.contains(index), slots[index].owned else { return .unowned }
        if tracked != nil, trackedCell == index { return .pressed }
        return slots[index].canFire ? .ready : .empty
    }

    private mutating func forgetTouch() {
        tracked = nil
        trackedCell = nil
    }

    private mutating func close() {
        isOpen = false
        forgetTouch()
    }
}
