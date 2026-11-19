import UIKit
import XCTest
@testable import Waddle

/// The weapon-select ring's drawing layer: where the seven wedges sit, what
/// each tells VoiceOver, and that a hidden ring exposes nothing. The rules
/// live in `WeaponRingModelTests` and the arithmetic in
/// `WeaponRingGeometryTests`; this pins only that the view follows them.
@MainActor
final class WeaponRingViewTests: XCTestCase {
    private let geometry = WeaponRingGeometry(pictureRect: CGRect(x: 30, y: 10, width: 720, height: 480))
    private let noSprites = [DoomGraphics.Bitmap?](repeating: nil, count: 9)

    private func model(owned: Set<Int>, canFire: Set<Int>? = nil, selected: Int? = nil) -> WeaponRingModel {
        var m = WeaponRingModel()
        m.slots = (0..<9).map { WeaponSlotState(owned: owned.contains($0), canFire: (canFire ?? owned).contains($0)) }
        m.selectedWeapon = selected
        return m
    }

    private func wedges(_ view: WeaponRingView) -> [UIView] {
        (0..<WeaponRingGeometry.wedgeCount).compactMap { i in
            view.subviews.first { $0.accessibilityIdentifier == "weaponCell\(i)" }
        }
    }

    private func makeView(_ m: WeaponRingModel, sprites: [DoomGraphics.Bitmap?]? = nil) -> WeaponRingView {
        let view = WeaponRingView(frame: CGRect(x: 0, y: 0, width: 780, height: 500))
        view.update(geometry: geometry, model: m, sprites: sprites ?? noSprites)
        return view
    }

    func testSevenWedgesWithTheGridsIdentifierScheme() {
        let view = makeView(model(owned: []))
        XCTAssertEqual(wedges(view).count, 7)
        XCTAssertNil(view.subviews.first { $0.accessibilityIdentifier == "weaponCell7" })
    }

    /// The centre of each wedge's frame (where XCUITest taps an element) is
    /// the wedge's midpoint, which hit-tests to that wedge.
    func testEachWedgeFrameIsCentredOnItsMidpoint() {
        let view = makeView(model(owned: []))
        for i in 0..<7 {
            let frame = view.wedgeFrameForTesting(i)
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            XCTAssertEqual(centre.x, geometry.wedgeMidpoint(i).x, accuracy: 1e-9)
            XCTAssertEqual(centre.y, geometry.wedgeMidpoint(i).y, accuracy: 1e-9)
            XCTAssertEqual(geometry.wedge(at: centre), i)
            XCTAssertEqual(frame.width, geometry.spriteSide, accuracy: 1e-9)
        }
    }

    func testLabelsNameTheResolvedWeapon() {
        let view = makeView(model(owned: [0, 1, 2, 7, 8], selected: 8))
        let found = wedges(view)
        XCTAssertEqual(found[0].accessibilityLabel, "chainsaw", "the preferred partner")
        XCTAssertEqual(found[1].accessibilityLabel, "pistol")
        XCTAssertEqual(found[2].accessibilityLabel, "shotgun", "the SSG is up, so the slot swaps")
        XCTAssertEqual(found[6].accessibilityLabel, "BFG", "an empty slot names its first weapon")
    }

    func testValuesAndTraitsFollowTheResolvedWeapon() {
        let view = makeView(model(owned: [0, 1, 4], canFire: [0, 1]))
        let found = wedges(view)
        XCTAssertEqual(found[1].accessibilityValue, "ready")
        XCTAssertEqual(found[1].accessibilityTraits, .button)
        XCTAssertEqual(found[4].accessibilityValue, "out of ammo")
        XCTAssertEqual(found[4].accessibilityTraits, .button, "out of ammo is still selectable")
        XCTAssertEqual(found[2].accessibilityValue, "not owned")
        XCTAssertEqual(found[2].accessibilityTraits, [.button, .notEnabled])
    }

    func testNilSpritesStillRender() {
        let view = makeView(model(owned: Set(0..<9)))
        for (i, wedge) in wedges(view).enumerated() {
            XCTAssertFalse(wedge.isHidden)
            XCTAssertFalse(view.hasSpriteForTesting(i))
        }
        // A short sprite table is not a crash either.
        view.update(geometry: geometry, model: model(owned: [1]), sprites: [])
        XCTAssertEqual(wedges(view).count, 7)
    }

    func testSpritesAreShownForTheDisplayedWeapon() {
        let pixel = DoomGraphics.Bitmap(width: 1, height: 1, rgba: [255, 0, 0, 255])
        var sprites = noSprites
        sprites[7] = pixel   // chainsaw only
        let view = makeView(model(owned: [0, 1, 7], selected: 1), sprites: sprites)
        XCTAssertTrue(view.hasSpriteForTesting(0), "slot 0 resolves to the chainsaw")
        XCTAssertFalse(view.hasSpriteForTesting(1))
    }

    func testTheSelectedSlotIsAccented() {
        let view = makeView(model(owned: [0, 1, 7], selected: 7))
        XCTAssertTrue(view.isAccentedForTesting(0))
        for i in 1..<7 { XCTAssertFalse(view.isAccentedForTesting(i), "wedge \(i)") }
    }

    /// Hidden, no wedge is an accessibility element, so nothing of the ring
    /// can sit on the screen's centre line in the accessibility hit test.
    func testWedgesAreAccessibilityElementsOnlyWhileShown() {
        let view = makeView(model(owned: [1]))
        view.isHidden = true
        XCTAssertTrue(wedges(view).allSatisfy { !$0.isAccessibilityElement })
        view.isHidden = false
        XCTAssertTrue(wedges(view).allSatisfy { $0.isAccessibilityElement })
        view.isHidden = true
        XCTAssertTrue(wedges(view).allSatisfy { !$0.isAccessibilityElement })
    }

    func testTheRingTakesNoTouches() {
        let view = makeView(model(owned: [1]))
        XCTAssertFalse(view.isUserInteractionEnabled)
        XCTAssertTrue(wedges(view).allSatisfy { !$0.isUserInteractionEnabled })
    }

    /// The end wedges' sprites stay above the centre line, where their
    /// panels are; every sprite is still aspect-fitted to the square.
    func testSpritesStayAboveTheCentreLine() {
        let square = DoomGraphics.Bitmap(width: 2, height: 2, rgba: [UInt8](repeating: 255, count: 16))
        let view = makeView(model(owned: Set(0..<9)), sprites: Array(repeating: square, count: 9))
        for i in 0..<7 {
            guard let sprite = view.spriteFrameForTesting(i) else { return XCTFail("wedge \(i) has no sprite") }
            XCTAssertLessThanOrEqual(sprite.maxY, geometry.center.y, "wedge \(i)")
            XCTAssertEqual(sprite.width, geometry.spriteSide, accuracy: 1e-6, "wedge \(i)")
        }
        let middle = view.spriteFrameForTesting(3)!
        XCTAssertEqual(middle.midY, geometry.wedgeMidpoint(3).y, accuracy: 1e-6, "an unconstrained sprite is not moved")
    }

    func testSpriteRectFitsAndNudges() {
        let box = CGRect(x: 0, y: 0, width: 40, height: 40)
        XCTAssertEqual(WeaponRingView.spriteRect(imageSize: CGSize(width: 20, height: 10), box: box, floorY: 100),
                       CGRect(x: 0, y: 10, width: 40, height: 20))
        XCTAssertEqual(WeaponRingView.spriteRect(imageSize: CGSize(width: 10, height: 10), box: box, floorY: 30),
                       CGRect(x: 0, y: -10, width: 40, height: 40))
        XCTAssertEqual(WeaponRingView.spriteRect(imageSize: .zero, box: box, floorY: 30), .zero)
    }

    /// The accessibility path is the panel. The wedge's frame is unchanged,
    /// so the centre XCUITest taps is still the wedge midpoint; that centre,
    /// and the centre of the panel's bounding box (in case a reader takes
    /// the frame from the path), are both on the drawn wedge.
    func testAccessibilityPathIsThePanelAndTapPointsAreOnTheDrawing() {
        let view = makeView(model(owned: [1]))
        view.isHidden = false
        let found = wedges(view)
        for i in 0..<7 {
            XCTAssertNotNil(found[i].accessibilityPath, "wedge \(i)")
            let frame = view.wedgeFrameForTesting(i)
            XCTAssertEqual(geometry.drawnWedge(at: CGPoint(x: frame.midX, y: frame.midY)), i, "frame centre \(i)")
            guard let path = view.panelPathForTesting(i) else { return XCTFail("no panel \(i)") }
            let box = path.boundingBoxOfPath
            XCTAssertEqual(geometry.drawnWedge(at: CGPoint(x: box.midX, y: box.midY)), i, "path box centre \(i)")
            XCTAssertTrue(path.contains(geometry.wedgeMidpoint(i)), "panel contains its midpoint \(i)")
        }
    }

    func testPanelPathLeavesAGap() {
        let c = CGPoint(x: 0, y: 0)
        let path = WeaponRingView.panelPath(center: c, inner: 40, outer: 100,
                                            start: .pi, end: .pi + .pi / 7, gap: 4)
        // The left horizon itself is in the gap; a point just inside the wedge is not.
        XCTAssertFalse(path.contains(CGPoint(x: -70, y: -0.5)))
        XCTAssertTrue(path.contains(CGPoint(x: -70, y: -10)))
    }
}
