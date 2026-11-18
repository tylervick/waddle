import XCTest
@testable import Waddle

/// The weapon-select grid's rules: when it opens, which finger may pick, when
/// it closes. Pure, so the rules are pinned without UIKit or the engine.
final class WeaponSelectModelTests: XCTestCase {
    private func openModel(owned: Set<Int> = []) -> WeaponSelectModel {
        var m = WeaponSelectModel()
        _ = m.hotspotTouchBegan(canOpen: true)
        for i in owned {
            m.slots[i] = WeaponSlotState(owned: true, canFire: true)
        }
        return m
    }

    func testOpensAndReleasesHeldInputs() {
        var m = WeaponSelectModel()
        XCTAssertEqual(m.hotspotTouchBegan(canOpen: true), [.releaseHeldInputs])
        XCTAssertTrue(m.isOpen)
    }

    func testDoesNotOpenWhenUnavailable() {
        var m = WeaponSelectModel()
        XCTAssertEqual(m.hotspotTouchBegan(canOpen: false), [])
        XCTAssertFalse(m.isOpen)
    }

    func testReTapClosesAndSelectsBest() {
        var m = openModel()
        XCTAssertEqual(m.hotspotTouchBegan(canOpen: true), [.selectBest])
        XCTAssertFalse(m.isOpen)
    }

    func testLiftInOwnedCellSelectsAndCloses() {
        var m = openModel(owned: [4])
        m.touchBegan("a", cell: 4)
        XCTAssertEqual(m.touchEnded("a", cell: 4), [.select(4)])
        XCTAssertFalse(m.isOpen)
    }

    func testLiftPicksTheCellItLiftsIn() {
        var m = openModel(owned: [1, 4])
        m.touchBegan("a", cell: 1)
        m.touchMoved("a", cell: 4)
        XCTAssertEqual(m.touchEnded("a", cell: 4), [.select(4)])
        XCTAssertFalse(m.isOpen)
    }

    func testLiftInUnownedCellOrGapKeepsGridOpen() {
        var m = openModel(owned: [4])
        m.touchBegan("a", cell: 4)
        XCTAssertEqual(m.touchEnded("a", cell: 2), [])
        XCTAssertTrue(m.isOpen)

        m.touchBegan("b", cell: 4)
        XCTAssertEqual(m.touchEnded("b", cell: nil), [])
        XCTAssertTrue(m.isOpen)

        // Both spent touches were dropped: a fresh touch can be tracked and pick.
        m.touchBegan("c", cell: 4)
        XCTAssertEqual(m.touchEnded("c", cell: 4), [.select(4)])
        XCTAssertFalse(m.isOpen)
    }

    func testOutOfAmmoWeaponIsStillSelectable() {
        var m = openModel()
        m.slots[3] = WeaponSlotState(owned: true, canFire: false)
        XCTAssertTrue(m.isSelectable(3))
        XCTAssertEqual(m.appearance(3), .empty)
        m.touchBegan("a", cell: 3)
        XCTAssertEqual(m.touchEnded("a", cell: 3), [.select(3)])
        XCTAssertFalse(m.isOpen)
    }

    func testTouchThatNeverBeganCannotPick() {
        var m = openModel(owned: [6])
        XCTAssertEqual(m.touchEnded("stick", cell: 6), [])
        XCTAssertTrue(m.isOpen)
    }

    func testSecondFingerIsIgnored() {
        var m = openModel(owned: [1, 4])
        m.touchBegan("a", cell: 1)
        m.touchBegan("b", cell: 4)
        XCTAssertEqual(m.touchEnded("b", cell: 4), [])
        XCTAssertTrue(m.isOpen)
        XCTAssertEqual(m.touchEnded("a", cell: 1), [.select(1)])
        XCTAssertFalse(m.isOpen)
    }

    func testForcedCloseForgetsTheFinger() {
        var m = openModel(owned: [1])
        m.touchBegan("a", cell: 1)
        m.availabilityChanged(canOpen: false)
        XCTAssertFalse(m.isOpen)
        XCTAssertEqual(m.touchEnded("a", cell: 1), [])
        XCTAssertFalse(m.isOpen)

        // Re-open: the stale finger must not pick from its old tracking.
        XCTAssertEqual(m.hotspotTouchBegan(canOpen: true), [.releaseHeldInputs])
        XCTAssertEqual(m.touchEnded("a", cell: 1), [])
        XCTAssertTrue(m.isOpen)
    }

    func testReTapCloseForgetsTheFinger() {
        var m = openModel(owned: [1])
        m.touchBegan("a", cell: 1)
        XCTAssertEqual(m.hotspotTouchBegan(canOpen: true), [.selectBest])
        XCTAssertFalse(m.isOpen)
        XCTAssertEqual(m.hotspotTouchBegan(canOpen: true), [.releaseHeldInputs])
        XCTAssertEqual(m.touchEnded("a", cell: 1), [])
        XCTAssertTrue(m.isOpen)
    }

    func testCancelledTouchPicksNothing() {
        var m = openModel(owned: [1])
        m.touchBegan("a", cell: 1)
        m.touchCancelled("a")
        XCTAssertEqual(m.touchEnded("a", cell: 1), [])
        XCTAssertTrue(m.isOpen)
    }

    func testAppearanceTable() {
        var m = openModel()
        m.slots[1] = WeaponSlotState(owned: true, canFire: true)
        m.slots[2] = WeaponSlotState(owned: true, canFire: false)
        XCTAssertEqual(m.appearance(0), .unowned)
        XCTAssertEqual(m.appearance(1), .ready)
        XCTAssertEqual(m.appearance(2), .empty)
        m.touchBegan("a", cell: 1)
        XCTAssertEqual(m.appearance(1), .pressed)
        m.touchMoved("a", cell: 0)
        XCTAssertEqual(m.appearance(0), .unowned)
        XCTAssertEqual(m.appearance(1), .ready)
    }

    func testSelectabilityIgnoresArt() {
        // The model takes no sprite input: owned is the whole rule.
        var m = WeaponSelectModel()
        m.slots[5] = WeaponSlotState(owned: true, canFire: false)
        XCTAssertTrue(m.isSelectable(5))
        XCTAssertFalse(m.isSelectable(0))
    }
}
