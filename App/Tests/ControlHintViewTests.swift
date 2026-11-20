import UIKit
import XCTest
@testable import Waddle

/// The control hints' drawing layer (issue #392). The rule is pinned in
/// `ControlHintModelTests` and the frames in `ControlHintGeometryTests`;
/// this pins that the view follows them, takes no touches and puts nothing
/// in the accessibility tree.
@MainActor
final class ControlHintViewTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 874, height: 402)
    private let picture = CGRect(x: 169, y: 0, width: 536, height: 402)

    private func geometry(_ style: WeaponSelectorStyle) -> ControlHintGeometry {
        ControlHintGeometry(style: style, pictureRect: picture, bounds: bounds, stickRadius: 60)
    }

    private func makeView(_ style: WeaponSelectorStyle = .ring) -> ControlHintView {
        let view = ControlHintView(frame: bounds)
        view.update(geometry: geometry(style))
        return view
    }

    private func allViews(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(allViews)
    }

    func testStartsHidden() {
        let view = makeView()
        XCTAssertEqual(view.alpha, 0)
        XCTAssertEqual(view.hints, .hidden)
    }

    func testWeaponsHintTakesTheZonesFrameInBothStyles() {
        for style in WeaponSelectorStyle.allCases {
            XCTAssertEqual(makeView(style).weaponsFrameForTesting, geometry(style).weaponsFrame, "\(style)")
        }
    }

    func testWeaponsAloneShowsNoMoveOrAim() {
        let view = makeView()
        view.show(.init(weapons: true, moveAndAim: false))
        XCTAssertEqual(view.alpha, 1)
        XCTAssertNil(view.moveFrameForTesting)
        XCTAssertNil(view.aimFrameForTesting)
    }

    func testMoveAndAimTakeTheirFramesWhenShown() {
        let view = makeView()
        view.show(.init(weapons: true, moveAndAim: true))
        XCTAssertEqual(view.alpha, 1)
        XCTAssertEqual(view.moveFrameForTesting, geometry(.ring).moveFrame)
        XCTAssertEqual(view.aimFrameForTesting, geometry(.ring).aimFrame)
    }

    func testHidingIsImmediate() {
        let view = makeView()
        view.show(.init(weapons: true, moveAndAim: true))
        view.show(.hidden)
        XCTAssertEqual(view.alpha, 0)
        XCTAssertEqual(view.layer.animationKeys() ?? [], [], "no fade-out left running")
    }

    func testTheLabelsSayWeaponsMoveAndAim() {
        let view = makeView()
        let texts = allViews(in: view).compactMap { ($0 as? UILabel)?.text }
        XCTAssertEqual(texts.sorted(), ["Aim", "Move", "Weapons"])
    }

    /// Shown or not, nothing in the hint is an accessibility element or
    /// takes a touch: the Weapons hint is on the screen's centre line, where
    /// an element breaks XCUITest's multi-touch tap.
    func testNothingIsAnAccessibilityElementOrTakesTouches() {
        let view = makeView()
        for hints in [ControlHintModel.Hints.hidden, .init(weapons: true, moveAndAim: true)] {
            view.show(hints)
            XCTAssertTrue(view.accessibilityElementsHidden)
            for sub in allViews(in: view) {
                XCTAssertFalse(sub.isAccessibilityElement, "\(type(of: sub))")
                XCTAssertFalse(sub.isUserInteractionEnabled, "\(type(of: sub))")
            }
            XCTAssertNil(view.hitTest(CGPoint(x: geometry(.ring).weaponsFrame.midX,
                                              y: geometry(.ring).weaponsFrame.midY), with: nil))
        }
    }
}
