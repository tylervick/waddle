import XCTest
@testable import Waddle

/// The weapon-select ring's gesture rules, one test (or more) per line of the
/// design's "Gestures" section. Pure: the caller hit-tests and passes in
/// where each touch is; the model answers with effects.
final class WeaponRingModelTests: XCTestCase {
    private let hotspot = WeaponRingPoint(wedge: nil, inHotspot: true, onDrawing: false)
    private let elsewhere = WeaponRingPoint(wedge: nil, inHotspot: false, onDrawing: false)
    /// On wedge `i`'s drawn panel, as at its midpoint.
    private func wedge(_ i: Int) -> WeaponRingPoint { WeaponRingPoint(wedge: i, inHotspot: false, onDrawing: true) }
    /// In the hotspot disc, 0.75 · r to r from the centre, where the generous
    /// band reaches in: over wedge `i` by that band, on no drawn panel.
    private func hotspotOverWedge(_ i: Int) -> WeaponRingPoint {
        WeaponRingPoint(wedge: i, inHotspot: true, onDrawing: false)
    }

    /// Fist, pistol and the rocket launcher by default; the shotgun is not.
    private func model(owned: Set<Int> = [0, 1, 4], selected: Int? = 1) -> WeaponRingModel {
        var m = WeaponRingModel()
        m.slots = (0..<9).map { WeaponSlotState(owned: owned.contains($0), canFire: $0 != 4) }
        m.selectedWeapon = selected
        return m
    }

    /// Opened by `id` in the hotspot, in a batch of its own.
    private func opened(by id: String = "opener", owned: Set<Int> = [0, 1, 4],
                        selected: Int? = 1) -> WeaponRingModel {
        var m = model(owned: owned, selected: selected)
        XCTAssertEqual(m.touchBegan(id, at: hotspot, canOpen: true, openAtBatchStart: false), [.releaseHeldInputs])
        return m
    }

    /// Open, with the opening tap already lifted.
    private func openIdle(owned: Set<Int> = [0, 1, 4], selected: Int? = 1) -> WeaponRingModel {
        var m = opened(owned: owned, selected: selected)
        XCTAssertEqual(m.touchEnded("opener", at: hotspot), [])
        XCTAssertTrue(m.isOpen)
        return m
    }

    // MARK: Closed

    func testTouchDownInTheHotspotOpensAndReleasesHeldInputs() {
        var m = model()
        XCTAssertEqual(m.touchBegan("a", at: hotspot, canOpen: true, openAtBatchStart: false), [.releaseHeldInputs])
        XCTAssertTrue(m.isOpen)
    }

    func testHotspotIsInertWhenTheRingMayNotOpen() {
        var m = model()
        XCTAssertNil(m.touchBegan("a", at: hotspot, canOpen: false, openAtBatchStart: false),
                     "not the ring's touch: routed as if the hotspot were not there")
        XCTAssertFalse(m.isOpen)
    }

    func testTouchDownOutsideTheHotspotIsNotTheRingsWhileClosed() {
        var m = model()
        XCTAssertNil(m.touchBegan("a", at: elsewhere, canOpen: true, openAtBatchStart: false))
        XCTAssertNil(m.touchBegan("b", at: wedge(3), canOpen: true, openAtBatchStart: false),
                     "a wedge's place is not live while the ring is closed")
        XCTAssertFalse(m.isOpen)
    }

    func testTheOpeningFingerHighlightsTheWedgeItMovesOver() {
        var m = opened()
        XCTAssertNil(m.highlightedSlot)
        m.touchMoved("opener", at: wedge(1))
        XCTAssertEqual(m.highlightedSlot, 1)
        XCTAssertEqual(m.appearance(1), .pressed)
        m.touchMoved("opener", at: wedge(4))
        XCTAssertEqual(m.highlightedSlot, 4)
        XCTAssertEqual(m.appearance(1), .ready)
        m.touchMoved("opener", at: elsewhere)
        XCTAssertNil(m.highlightedSlot)
    }

    func testAnUnselectableWedgeIsNeverHighlighted() {
        var m = opened()
        m.touchMoved("opener", at: wedge(2))
        XCTAssertNil(m.highlightedSlot)
        XCTAssertEqual(m.appearance(2), .unowned)
    }

    func testTheOpeningFingerLiftingOverASelectableWedgePicksAndCloses() {
        var m = opened()
        m.touchMoved("opener", at: wedge(0))
        XCTAssertEqual(m.touchEnded("opener", at: wedge(0)), [.select(0)])
        XCTAssertFalse(m.isOpen)
    }

    /// The lift decides, not the last move.
    func testTheLiftPointDecides() {
        var m = opened()
        m.touchMoved("opener", at: wedge(2))
        XCTAssertEqual(m.touchEnded("opener", at: wedge(1)), [.select(1)])
        XCTAssertFalse(m.isOpen)
    }

    func testATapThatNeverLeavesTheHotspotLeavesTheRingOpen() {
        var m = opened()
        m.touchMoved("opener", at: hotspot)
        XCTAssertEqual(m.touchEnded("opener", at: hotspot), [])
        XCTAssertTrue(m.isOpen)
        XCTAssertNil(m.highlightedSlot)
    }

    /// The generous band reaches into the hotspot disc. A finger that never
    /// left the hotspot is a tap there all the same: it neither picks nor
    /// lights the wedge.
    func testATapInTheHotspotOverAWedgeIsStillATap() {
        var m = opened()
        m.touchMoved("opener", at: hotspotOverWedge(4))
        XCTAssertNil(m.highlightedSlot)
        XCTAssertEqual(m.touchEnded("opener", at: hotspotOverWedge(4)), [])
        XCTAssertTrue(m.isOpen)
    }

    func testTheOpeningFingerLiftingElsewhereClosesWithoutAPick() {
        var m = opened()
        m.touchMoved("opener", at: elsewhere)
        XCTAssertEqual(m.touchEnded("opener", at: elsewhere), [])
        XCTAssertFalse(m.isOpen)
    }

    func testTheOpeningFingerLiftingOverAnUnselectableWedgeCloses() {
        var m = opened()
        m.touchMoved("opener", at: wedge(2))
        XCTAssertEqual(m.touchEnded("opener", at: wedge(2)), [])
        XCTAssertFalse(m.isOpen)
    }

    func testTheOpeningFingerThatLeftAndCameBackToTheHotspotCloses() {
        var m = opened()
        m.touchMoved("opener", at: elsewhere)
        m.touchMoved("opener", at: hotspot)
        XCTAssertEqual(m.touchEnded("opener", at: hotspot), [])
        XCTAssertFalse(m.isOpen)
    }

    func testTheOpeningFingerLiftingOutsideTheHotspotWithoutAMoveCloses() {
        var m = opened()
        XCTAssertEqual(m.touchEnded("opener", at: elsewhere), [])
        XCTAssertFalse(m.isOpen)
    }

    // MARK: Open

    func testTouchDownOnAWedgeIsTrackedAndPicksOnLift() {
        var m = openIdle()
        XCTAssertEqual(m.touchBegan("b", at: wedge(4), canOpen: false, openAtBatchStart: true), [])
        XCTAssertEqual(m.highlightedSlot, 4)
        XCTAssertEqual(m.touchEnded("b", at: wedge(4)), [.select(4)])
        XCTAssertFalse(m.isOpen)
    }

    func testAWedgeTouchMayPickAnotherWedgeItSlidesTo() {
        var m = openIdle()
        _ = m.touchBegan("b", at: wedge(2), canOpen: false, openAtBatchStart: true)
        XCTAssertNil(m.highlightedSlot)
        m.touchMoved("b", at: wedge(0))
        XCTAssertEqual(m.highlightedSlot, 0)
        XCTAssertEqual(m.touchEnded("b", at: wedge(0)), [.select(0)])
    }

    func testAWedgeTouchLiftingElsewhereLeavesTheRingOpen() {
        var m = openIdle()
        _ = m.touchBegan("b", at: wedge(1), canOpen: false, openAtBatchStart: true)
        XCTAssertEqual(m.touchEnded("b", at: elsewhere), [])
        XCTAssertTrue(m.isOpen)
        XCTAssertNil(m.highlightedSlot)
    }

    func testAWedgeTouchLiftingOverAnUnselectableWedgeLeavesTheRingOpen() {
        var m = openIdle()
        _ = m.touchBegan("b", at: wedge(2), canOpen: false, openAtBatchStart: true)
        XCTAssertEqual(m.touchEnded("b", at: wedge(2)), [])
        XCTAssertTrue(m.isOpen)
    }

    /// The grid's re-tap selects the best weapon; the ring's only closes.
    func testTouchDownInTheHotspotWhileOpenClosesWithoutAPick() {
        var m = openIdle()
        XCTAssertEqual(m.touchBegan("b", at: hotspot, canOpen: true, openAtBatchStart: true), [])
        XCTAssertFalse(m.isOpen)
        XCTAssertEqual(m.touchEnded("b", at: hotspot), [], "its lift does nothing")
        XCTAssertFalse(m.isOpen)
    }

    func testTouchDownElsewhereWhileOpenClosesAndIsConsumed() {
        var m = openIdle()
        XCTAssertEqual(m.touchBegan("b", at: elsewhere, canOpen: true, openAtBatchStart: true), [],
                       "consumed: not nil")
        XCTAssertFalse(m.isOpen)
        XCTAssertEqual(m.touchEnded("b", at: wedge(1)), [])
    }

    /// Open, a touch-down in the hotspot disc where the generous band reaches
    /// in (the ring's hole) is on no drawn wedge: it closes without a pick,
    /// and its lift over the same spot picks nothing either.
    func testWhileOpenATouchDownInTheHoleOverTheGenerousBandCloses() {
        var m = openIdle()
        XCTAssertEqual(m.touchBegan("b", at: hotspotOverWedge(4), canOpen: true, openAtBatchStart: true), [])
        XCTAssertFalse(m.isOpen)
        XCTAssertEqual(m.touchEnded("b", at: hotspotOverWedge(4)), [])
        XCTAssertFalse(m.isOpen)
    }

    // MARK: Strict band for touch-downs, generous band for a tracked finger

    /// What `WeaponRingGeometry.locate` reports at 1.2 · R (a button just
    /// past the outer edge) and at 0.85 · r (under the inner edge, in the
    /// hotspot disc): the generous wedge, but not on the drawing.
    private func pastOuterEdge(_ i: Int) -> WeaponRingPoint {
        WeaponRingPoint(wedge: i, inHotspot: false, onDrawing: false)
    }
    private func underInnerEdge(_ i: Int) -> WeaponRingPoint {
        WeaponRingPoint(wedge: i, inHotspot: true, onDrawing: false)
    }

    func testATouchDownPastTheOuterEdgeClosesWithoutAPick() {
        var m = openIdle()
        XCTAssertEqual(m.touchBegan("b", at: pastOuterEdge(1), canOpen: true, openAtBatchStart: true), [])
        XCTAssertFalse(m.isOpen)
        XCTAssertEqual(m.touchEnded("b", at: pastOuterEdge(1)), [], "its lift picks nothing")
        XCTAssertFalse(m.isOpen)
    }

    func testATouchDownUnderTheInnerEdgeClosesWithoutAPick() {
        var m = openIdle()
        XCTAssertEqual(m.touchBegan("b", at: underInnerEdge(1), canOpen: true, openAtBatchStart: true), [])
        XCTAssertFalse(m.isOpen)
        XCTAssertEqual(m.touchEnded("b", at: underInnerEdge(1)), [])
        XCTAssertFalse(m.isOpen)
    }

    /// A tracked slide may still overshoot the drawing and pick.
    func testATrackedSlideOvershootingTheOuterEdgePicks() {
        var m = openIdle()
        _ = m.touchBegan("b", at: wedge(4), canOpen: false, openAtBatchStart: true)
        m.touchMoved("b", at: pastOuterEdge(1))
        XCTAssertEqual(m.highlightedSlot, 1)
        XCTAssertEqual(m.touchEnded("b", at: pastOuterEdge(1)), [.select(1)])
        XCTAssertFalse(m.isOpen)
    }

    func testTheOpeningSlideOvershootingTheOuterEdgePicks() {
        var m = opened()
        m.touchMoved("opener", at: pastOuterEdge(0))
        XCTAssertEqual(m.touchEnded("opener", at: pastOuterEdge(0)), [.select(0)])
    }

    /// Back in the hole after leaving the hotspot, the generous band still
    /// reaches there (0.75 · r up), so the lift picks.
    func testAnOpenerThatLeftAndLiftsUnderTheInnerEdgePicks() {
        var m = opened()
        m.touchMoved("opener", at: wedge(1))
        XCTAssertEqual(m.touchEnded("opener", at: underInnerEdge(1)), [.select(1)])
    }

    // MARK: One finger at a time

    func testOnlyOneFingerIsTracked() {
        var m = openIdle()
        _ = m.touchBegan("b", at: wedge(1), canOpen: false, openAtBatchStart: true)
        XCTAssertEqual(m.touchBegan("c", at: wedge(4), canOpen: false, openAtBatchStart: true), [],
                       "a second wedge touch is consumed")
        m.touchMoved("c", at: wedge(0))
        XCTAssertEqual(m.highlightedSlot, 1, "the untracked finger does not steer the highlight")
        XCTAssertEqual(m.touchEnded("c", at: wedge(4)), [], "nor pick")
        XCTAssertTrue(m.isOpen)
        XCTAssertEqual(m.touchEnded("b", at: wedge(1)), [.select(1)])
    }

    func testAWedgeTouchWhileTheOpeningFingerIsDownIsIgnored() {
        var m = opened()
        XCTAssertEqual(m.touchBegan("b", at: wedge(4), canOpen: false, openAtBatchStart: true), [])
        XCTAssertEqual(m.touchEnded("b", at: wedge(4)), [])
        XCTAssertTrue(m.isOpen)
        XCTAssertEqual(m.touchEnded("opener", at: wedge(1)), [.select(1)])
    }

    func testAFreshTouchIsTrackedOnceTheLastOneLifts() {
        var m = openIdle()
        _ = m.touchBegan("b", at: wedge(2), canOpen: false, openAtBatchStart: true)
        _ = m.touchEnded("b", at: wedge(2))
        _ = m.touchBegan("c", at: wedge(1), canOpen: false, openAtBatchStart: true)
        XCTAssertEqual(m.touchEnded("c", at: wedge(1)), [.select(1)])
    }

    /// A finger in the same `touchesBegan` batch as the one that opened the
    /// ring is consumed: it can neither pick nor steer.
    func testAFingerInTheOpeningBatchIsConsumed() {
        var m = model()
        _ = m.touchBegan("opener", at: hotspot, canOpen: true, openAtBatchStart: false)
        XCTAssertEqual(m.touchBegan("b", at: wedge(1), canOpen: false, openAtBatchStart: false), [])
        XCTAssertEqual(m.touchBegan("c", at: elsewhere, canOpen: false, openAtBatchStart: false), [],
                       "consumed, and it does not close the ring it arrived with")
        XCTAssertTrue(m.isOpen)
        m.touchMoved("b", at: wedge(4))
        XCTAssertNil(m.highlightedSlot)
        XCTAssertEqual(m.touchEnded("b", at: wedge(1)), [])
        XCTAssertTrue(m.isOpen)
    }

    /// Likewise the batch that closed it: a hotspot touch in it does not
    /// reopen the ring.
    func testAFingerInTheClosingBatchIsConsumed() {
        var m = openIdle()
        XCTAssertEqual(m.touchBegan("b", at: elsewhere, canOpen: true, openAtBatchStart: true), [])
        XCTAssertFalse(m.isOpen)
        XCTAssertEqual(m.touchBegan("c", at: hotspot, canOpen: true, openAtBatchStart: true), [])
        XCTAssertFalse(m.isOpen)
    }

    // MARK: Closing without a pick

    func testForcedCloseForgetsTheTrackedFinger() {
        var m = opened()
        m.touchMoved("opener", at: wedge(1))
        m.availabilityChanged(canOpen: false)
        XCTAssertFalse(m.isOpen)
        XCTAssertNil(m.highlightedSlot)
        XCTAssertEqual(m.touchEnded("opener", at: wedge(1)), [], "a forgotten finger cannot pick")

        var n = openIdle()
        _ = n.touchBegan("b", at: wedge(1), canOpen: false, openAtBatchStart: true)
        n.availabilityChanged(canOpen: false)
        _ = n.touchBegan("c", at: hotspot, canOpen: true, openAtBatchStart: false)
        XCTAssertTrue(n.isOpen)
        XCTAssertEqual(n.touchEnded("b", at: wedge(1)), [], "nor after the ring reopens")
    }

    func testAvailabilityStillTrueKeepsTheRingOpen() {
        var m = openIdle()
        m.availabilityChanged(canOpen: true)
        XCTAssertTrue(m.isOpen)
    }

    func testCancelledTouchNeverPicksAndLeavesTheRingOpen() {
        var m = opened()
        m.touchMoved("opener", at: wedge(1))
        m.touchCancelled("opener")
        XCTAssertTrue(m.isOpen)
        XCTAssertNil(m.highlightedSlot)
        XCTAssertEqual(m.touchEnded("opener", at: wedge(1)), [])
        XCTAssertTrue(m.isOpen)
    }

    // MARK: Shared slots

    func testASharedSlotPicksTheResolvedWeapon() {
        var m = openIdle(owned: [0, 1, 7], selected: 1)
        _ = m.touchBegan("b", at: wedge(0), canOpen: false, openAtBatchStart: true)
        XCTAssertEqual(m.touchEnded("b", at: wedge(0)), [.select(7)], "chainsaw preferred")

        var n = openIdle(owned: [0, 1, 7], selected: 7)
        _ = n.touchBegan("b", at: wedge(0), canOpen: false, openAtBatchStart: true)
        XCTAssertEqual(n.touchEnded("b", at: wedge(0)), [.select(0)], "swaps to the fist")

        var o = openIdle(owned: [1, 2, 8], selected: 8)
        _ = o.touchBegan("b", at: wedge(2), canOpen: false, openAtBatchStart: true)
        XCTAssertEqual(o.touchEnded("b", at: wedge(2)), [.select(2)], "swaps to the shotgun")
    }

    // MARK: Drawing state

    func testSelectedSlotFollowsTheSelectedWeapon() {
        XCTAssertEqual(model(selected: 7).selectedSlot, 0)
        XCTAssertEqual(model(selected: 8).selectedSlot, 2)
        XCTAssertEqual(model(selected: 4).selectedSlot, 4)
        XCTAssertNil(model(selected: nil).selectedSlot)
    }

    func testAppearance() {
        let m = openIdle(owned: [0, 1, 4])
        XCTAssertEqual(m.appearance(1), .ready)
        XCTAssertEqual(m.appearance(2), .unowned)
        XCTAssertEqual(m.appearance(4), .empty, "owned, cannot fire")
        XCTAssertEqual(m.appearance(9), .unowned)
        XCTAssertTrue(m.isSelectable(4), "out of ammo is still selectable")
        XCTAssertFalse(m.isSelectable(2))
        XCTAssertEqual(m.resolvedWeapon(0), 0)
        XCTAssertNil(m.resolvedWeapon(2))
    }
}
