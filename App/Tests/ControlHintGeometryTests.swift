import CoreGraphics
import XCTest
@testable import Waddle

/// Where the control hints sit (issue #392): the Weapons hint is the weapon
/// zone of the installed selector style, and Move/Aim are stick-sized
/// circles in the middle of the stick column and the drag-turn column.
final class ControlHintGeometryTests: XCTestCase {
    /// A 402 x 874 phone held upright: a 4:3 picture across the middle.
    private let portraitBounds = CGRect(x: 0, y: 0, width: 402, height: 874)
    private let portraitPicture = CGRect(x: 0, y: 286.25, width: 402, height: 301.5)
    /// The same phone on its side: the 4:3 picture pillarboxed.
    private let landscapeBounds = CGRect(x: 0, y: 0, width: 874, height: 402)
    private let landscapePicture = CGRect(x: 169, y: 0, width: 536, height: 402)

    private var cases: [(name: String, bounds: CGRect, picture: CGRect)] {
        [("portrait", portraitBounds, portraitPicture), ("landscape", landscapeBounds, landscapePicture)]
    }

    private func geometry(_ style: WeaponSelectorStyle, bounds: CGRect, picture: CGRect,
                          controlsArea: CGRect? = nil, stickRadius: CGFloat = 60) -> ControlHintGeometry {
        ControlHintGeometry(style: style, pictureRect: picture, bounds: bounds,
                            controlsArea: controlsArea, stickRadius: stickRadius)
    }

    func testRingHintIsTheRingsHotspotDisc() {
        for c in cases {
            let ring = WeaponRingGeometry(pictureRect: c.picture)
            let hint = geometry(.ring, bounds: c.bounds, picture: c.picture)
            XCTAssertEqual(hint.weaponsFrame, ring.hotspot, c.name)
            XCTAssertEqual(hint.weaponsShape, .disc(center: ring.center, radius: ring.innerRadius), c.name)
            XCTAssertFalse(hint.weaponsFrame.isEmpty, c.name)
        }
    }

    func testGridHintIsTheGridsHotspotRectangle() {
        for c in cases {
            let grid = WeaponSelectGeometry(pictureRect: c.picture)
            let hint = geometry(.grid, bounds: c.bounds, picture: c.picture)
            XCTAssertEqual(hint.weaponsFrame, grid.hotspot, c.name)
            XCTAssertEqual(hint.weaponsShape, .rectangle, c.name)
            XCTAssertFalse(hint.weaponsFrame.isEmpty, c.name)
        }
    }

    /// The two styles' zones are different shapes in different places, so a
    /// hint drawn for the wrong style would be caught above.
    func testTheTwoStylesZonesDiffer() {
        for c in cases {
            XCTAssertNotEqual(geometry(.ring, bounds: c.bounds, picture: c.picture).weaponsFrame,
                              geometry(.grid, bounds: c.bounds, picture: c.picture).weaponsFrame, c.name)
        }
    }

    /// On a picture wide enough that the disc runs off its bottom edge, the
    /// hint's frame is cut off with the zone, not left as the whole disc.
    func testRingHintIsClippedWithTheZoneOnAWidePicture() {
        let picture = CGRect(x: 0, y: 0, width: 874, height: 402)
        let ring = WeaponRingGeometry(pictureRect: picture)
        let hint = geometry(.ring, bounds: landscapeBounds, picture: picture)
        XCTAssertEqual(hint.weaponsFrame, ring.hotspot)
        XCTAssertEqual(hint.weaponsFrame.maxY, picture.maxY)
        XCTAssertLessThan(hint.weaponsFrame.height, 2 * ring.innerRadius)
    }

    func testMoveAndAimSitInTheMiddleOfTheirColumns() {
        for c in cases {
            for style in WeaponSelectorStyle.allCases {
                let hint = geometry(style, bounds: c.bounds, picture: c.picture)
                let split = c.bounds.width * TouchTrackRouter.stickColumnFraction
                XCTAssertEqual(hint.moveFrame.midX, split / 2, accuracy: 1e-9, c.name)
                XCTAssertEqual(hint.aimFrame.midX, (split + c.bounds.width) / 2, accuracy: 1e-9, c.name)
                XCTAssertEqual(hint.moveFrame.midY, c.bounds.midY, accuracy: 1e-9, c.name)
                XCTAssertEqual(hint.aimFrame.midY, c.bounds.midY, accuracy: 1e-9, c.name)
                XCTAssertEqual(hint.moveFrame.size, CGSize(width: 120, height: 120), c.name)
                XCTAssertEqual(hint.aimFrame.size, CGSize(width: 120, height: 120), c.name)
            }
        }
    }

    /// Each names the side a touch there would start: `TouchTrackRouter`
    /// routes Move's centre to the stick and Aim's to the turn.
    func testMoveAndAimNameTheSideTheRouterGivesThem() {
        for c in cases {
            let hint = geometry(.ring, bounds: c.bounds, picture: c.picture)
            let router = TouchTrackRouter(overlayWidth: c.bounds.width, scheme: .modern, buttons: [])
            XCTAssertEqual(router.route(CGPoint(x: hint.moveFrame.midX, y: hint.moveFrame.midY),
                                        stickTracking: false, turnTracking: false), .stick, c.name)
            XCTAssertEqual(router.route(CGPoint(x: hint.aimFrame.midX, y: hint.aimFrame.midY),
                                        stickTracking: false, turnTracking: false), .turn, c.name)
        }
    }

    func testMoveAndAimFollowTheStickRadius() {
        let hint = geometry(.ring, bounds: landscapeBounds, picture: landscapePicture, stickRadius: 94)
        XCTAssertEqual(hint.moveFrame.size, CGSize(width: 188, height: 188))
        XCTAssertEqual(hint.aimFrame.size, CGSize(width: 188, height: 188))
    }

    /// Half open, the stick and the turn start only below the fold, so that
    /// is where Move and Aim go.
    func testMoveAndAimStayInTheControlsAreaWhenHalfOpen() {
        let area = CGRect(x: 0, y: 457, width: 402, height: 417)
        let hint = geometry(.ring, bounds: portraitBounds, picture: CGRect(x: 0, y: 60, width: 402, height: 301.5),
                            controlsArea: area)
        XCTAssertEqual(hint.moveFrame.midY, area.midY, accuracy: 1e-9)
        XCTAssertEqual(hint.aimFrame.midY, area.midY, accuracy: 1e-9)
        XCTAssertTrue(area.contains(hint.moveFrame))
        XCTAssertTrue(area.contains(hint.aimFrame))
    }
}
