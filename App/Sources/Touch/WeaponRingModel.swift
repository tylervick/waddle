/// The rules of the weapon-select ring: when it opens, which finger may pick,
/// when it closes. Pure, like `WeaponSelectModel`, so `WaddleTests` pins them
/// without UIKit or the engine. The caller hit-tests (`WeaponRingGeometry`)
/// and passes in where each touch is; the model answers with effects.
///
/// Unlike the grid, the finger that opens the ring is tracked: press in the
/// hotspot, slide over a wedge and lift to pick in one gesture. A tap that
/// never leaves the hotspot leaves the ring open for a second tap on a wedge.
/// See docs/superpowers/specs/2026-11-19-weapon-select-ring-design.md.
struct WeaponRingModel {
    /// `select` carries an engine weapon number, already resolved through
    /// the shared slots, not a slot index.
    enum Effect: Equatable { case releaseHeldInputs, select(Int) }

    private(set) var isOpen = false
    /// Always nine entries, in engine weapon order; starts all unowned.
    var slots = [WeaponSlotState](repeating: WeaponSlotState(owned: false, canFire: false),
                                  count: WeaponSelectModel.names.count)
    /// The engine's weapon up or pending (`WoofIOS_GetSelectedWeapon`), which
    /// decides how a shared slot resolves; nil when unknown.
    var selectedWeapon: Int?

    /// The one finger allowed to pick. Fingers already down when the ring
    /// opened never begin here, so they can neither pick nor light a wedge.
    private var tracked: AnyHashable?
    /// Where the tracked finger is now.
    private var trackedPoint: WeaponRingPoint?
    /// The tracked finger is the one that opened the ring...
    private var trackedIsOpener = false
    /// ...and it has been outside the hotspot since.
    private var openerLeftHotspot = false

    /// A touch-down. Returns nil when the touch is not the ring's (closed,
    /// and not an opening touch in the hotspot): the caller routes it as if
    /// the ring did not exist. Otherwise the touch is consumed and the
    /// effects are to be performed.
    ///
    /// `canOpen` is the engine's and overlay's "may open" answer; it is read
    /// only for a touch in the hotspot while closed. `openAtBatchStart` is
    /// `isOpen` as it was when this `touchesBegan` batch started: a finger
    /// in the same batch as the touch that opened or closed the ring is
    /// consumed and does nothing else.
    ///
    /// Open, a touch-down on a drawn wedge (the strict band, `drawnWedge`) is
    /// tracked if no finger is. Any other touch-down, in the hotspot, just
    /// off the drawing (a button past the outer edge, a thumb coming back
    /// under the inner edge) or anywhere else, closes the ring without a
    /// pick. The hotspot and the drawn band do not overlap, so there is no
    /// tie to break. Once tracked, a finger moves and lifts by the generous
    /// band, so a slide may overshoot.
    mutating func touchBegan(_ id: AnyHashable, at point: WeaponRingPoint,
                             canOpen: Bool, openAtBatchStart: Bool) -> [Effect]? {
        if isOpen != openAtBatchStart { return [] }
        guard isOpen else {
            guard point.inHotspot, canOpen else { return nil }
            isOpen = true
            track(id, at: point, opener: true)
            return [.releaseHeldInputs]
        }
        if point.drawnWedge != nil {
            if tracked == nil { track(id, at: point, opener: false) }
            return []
        }
        close()
        return []
    }

    mutating func touchMoved(_ id: AnyHashable, at point: WeaponRingPoint) {
        guard isOpen, id == tracked else { return }
        trackedPoint = point
        if trackedIsOpener, !point.inHotspot { openerLeftHotspot = true }
    }

    /// The tracked finger's lift. Over a selectable wedge it picks and
    /// closes. Otherwise the opening finger leaves the ring open only if it
    /// never left the hotspot (a tap), and closes it if it did; a finger that
    /// began on a wedge leaves the ring open. Untracked lifts do nothing.
    mutating func touchEnded(_ id: AnyHashable, at point: WeaponRingPoint) -> [Effect] {
        guard isOpen, id == tracked else { return [] }
        let opener = trackedIsOpener
        let wasTap = opener && isTap(endingAt: point)
        forgetTouch()
        if let weapon = pick(at: point, tap: wasTap) {
            close()
            return [.select(weapon)]
        }
        if opener, !wasTap { close() }
        return []
    }

    /// A cancelled touch never picks; the ring stays as it is.
    mutating func touchCancelled(_ id: AnyHashable) {
        if id == tracked { forgetTouch() }
    }

    /// Polled: the "may open" answer. false (a menu, the automap, death, the
    /// keyboard) closes and forgets the finger, so its lift cannot pick.
    mutating func availabilityChanged(canOpen: Bool) {
        if !canOpen { close() }
    }

    /// The weapon a pick of `slot` would give.
    func resolvedWeapon(_ slot: Int) -> Int? {
        WeaponRingSlots.resolve(slot, slots: slots, selected: selectedWeapon)
    }

    func isSelectable(_ slot: Int) -> Bool { resolvedWeapon(slot) != nil }

    /// The slot holding the selected weapon, for the accent outline.
    var selectedSlot: Int? { selectedWeapon.flatMap(WeaponRingSlots.slot(of:)) }

    /// The wedge the tracked finger would pick if it lifted now.
    var highlightedSlot: Int? {
        guard isOpen, tracked != nil, let point = trackedPoint else { return nil }
        return pick(at: point, tap: trackedIsOpener && isTap(endingAt: point)).flatMap { _ in point.wedge }
    }

    /// The resolved weapon's state: unowned for an empty slot, pressed while
    /// highlighted, else ready or (owned but unable to fire) empty.
    func appearance(_ slot: Int) -> WeaponCellAppearance {
        guard let weapon = resolvedWeapon(slot) else { return .unowned }
        if highlightedSlot == slot { return .pressed }
        return slots[weapon].canFire ? .ready : .empty
    }

    /// The opening finger has not left the hotspot, and is in it now.
    private func isTap(endingAt point: WeaponRingPoint) -> Bool {
        !openerLeftHotspot && point.inHotspot
    }

    /// A tap never picks, even where the generous band reaches into the
    /// hotspot (0.75 · r to r): a finger that never left the hotspot is a tap.
    private func pick(at point: WeaponRingPoint, tap: Bool) -> Int? {
        guard !tap, let wedge = point.wedge else { return nil }
        return resolvedWeapon(wedge)
    }

    private mutating func track(_ id: AnyHashable, at point: WeaponRingPoint, opener: Bool) {
        tracked = id
        trackedPoint = point
        trackedIsOpener = opener
        openerLeftHotspot = opener && !point.inHotspot
    }

    private mutating func forgetTouch() {
        tracked = nil
        trackedPoint = nil
        trackedIsOpener = false
        openerLeftHotspot = false
    }

    private mutating func close() {
        isOpen = false
        forgetTouch()
    }
}
