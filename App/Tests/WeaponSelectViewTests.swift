import UIKit
import XCTest
@testable import Waddle

/// The weapon-select grid's drawing layer: where the nine cells sit and what
/// each one tells VoiceOver. The rules live in `WeaponSelectModelTests` and
/// the layout arithmetic in `WeaponSelectGeometryTests`; this pins only that
/// the view follows them.
@MainActor
final class WeaponSelectViewTests: XCTestCase {
    private let geometry = WeaponSelectGeometry(pictureRect: CGRect(x: 30, y: 10, width: 720, height: 480))
    private let noSprites = [DoomGraphics.Bitmap?](repeating: nil, count: WeaponSelectGeometry.cellCount)

    private func cells(_ view: WeaponSelectView) -> [UIView] {
        (0..<WeaponSelectGeometry.cellCount).compactMap { i in
            view.subviews.first { $0.accessibilityIdentifier == "weaponCell\(i)" }
        }
    }

    func testCellsFollowGeometry() {
        let view = WeaponSelectView(frame: CGRect(x: 0, y: 0, width: 780, height: 500))
        view.update(geometry: geometry, model: WeaponSelectModel(), sprites: noSprites)
        for i in 0..<WeaponSelectGeometry.cellCount {
            XCTAssertEqual(view.cellFrameForTesting(i), geometry.cellFrame(i), "cell \(i)")
        }
    }

    func testNilSpriteCellStillRenders() {
        var model = WeaponSelectModel()
        model.slots = model.slots.map { _ in WeaponSlotState(owned: true, canFire: true) }
        let view = WeaponSelectView(frame: CGRect(x: 0, y: 0, width: 780, height: 500))
        view.update(geometry: geometry, model: model, sprites: noSprites)

        let found = cells(view)
        XCTAssertEqual(found.count, 9)
        for (i, cell) in found.enumerated() {
            XCTAssertEqual(cell.accessibilityLabel, WeaponSelectModel.names[i])
            XCTAssertFalse(cell.isHidden)
        }
    }

    func testAccessibilityValueFollowsState() {
        var model = WeaponSelectModel()
        model.slots[0] = WeaponSlotState(owned: false, canFire: false)
        model.slots[1] = WeaponSlotState(owned: true, canFire: true)
        model.slots[2] = WeaponSlotState(owned: true, canFire: false)
        let view = WeaponSelectView(frame: CGRect(x: 0, y: 0, width: 780, height: 500))
        view.update(geometry: geometry, model: model, sprites: noSprites)

        let found = cells(view)
        XCTAssertEqual(found.count, 9)
        XCTAssertEqual(found[0].accessibilityValue, "not owned")
        XCTAssertEqual(found[1].accessibilityValue, "ready")
        XCTAssertEqual(found[2].accessibilityValue, "out of ammo")
    }

    /// Sprites are 1.25x native size in the predecessor's 480x320 screen,
    /// scaled by the picture's limiting axis: on a 3:2 picture both axes
    /// agree, and on a widescreen one the height limits, so a sprite is not
    /// cropped by a cell that is a quarter of the picture's height.
    func testSpriteScaleFollowsThePicturesLimitingAxis() {
        let view = WeaponSelectView(frame: CGRect(x: 0, y: 0, width: 900, height: 500))

        view.update(geometry: geometry, model: WeaponSelectModel(), sprites: noSprites)
        XCTAssertEqual(view.spritePixelScaleForTesting(), 1.25 * 720 / 480, accuracy: 1e-9,
                       "a 3:2 picture scales as both axes do")

        let wide = WeaponSelectGeometry(pictureRect: CGRect(x: 0, y: 0, width: 874, height: 402))
        view.update(geometry: wide, model: WeaponSelectModel(), sprites: noSprites)
        XCTAssertEqual(view.spritePixelScaleForTesting(), 1.25 * 402 / 320, accuracy: 1e-9,
                       "a widescreen picture scales by its height")
    }

    /// VoiceOver: every cell is a button, and one the model would not pick
    /// (not owned) is announced as dimmed. Out of ammo is still pickable.
    func testCellTraitsFollowSelectability() {
        var model = WeaponSelectModel()
        model.slots[0] = WeaponSlotState(owned: false, canFire: false)
        model.slots[1] = WeaponSlotState(owned: true, canFire: true)
        model.slots[2] = WeaponSlotState(owned: true, canFire: false)
        let view = WeaponSelectView(frame: CGRect(x: 0, y: 0, width: 780, height: 500))
        view.update(geometry: geometry, model: model, sprites: noSprites)

        let found = cells(view)
        XCTAssertEqual(found.count, 9)
        for cell in found { XCTAssertTrue(cell.accessibilityTraits.contains(.button)) }
        XCTAssertTrue(found[0].accessibilityTraits.contains(.notEnabled))
        XCTAssertFalse(found[1].accessibilityTraits.contains(.notEnabled))
        XCTAssertFalse(found[2].accessibilityTraits.contains(.notEnabled))

        model.slots[0] = WeaponSlotState(owned: true, canFire: true)
        view.update(geometry: geometry, model: model, sprites: noSprites)
        XCTAssertFalse(found[0].accessibilityTraits.contains(.notEnabled),
                       "picking a weapon up enables its cell")
    }

    /// The overlay owns every touch; the grid must never swallow one.
    func testViewAndCellsTakeNoTouches() {
        let view = WeaponSelectView(frame: CGRect(x: 0, y: 0, width: 780, height: 500))
        view.update(geometry: geometry, model: WeaponSelectModel(), sprites: noSprites)
        XCTAssertFalse(view.isUserInteractionEnabled)
        for cell in cells(view) { XCTAssertFalse(cell.isUserInteractionEnabled) }
    }
}
