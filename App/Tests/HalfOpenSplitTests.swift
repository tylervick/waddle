import UIKit
import XCTest
@testable import Waddle

/// Issue #373: an iPhone Duo standing half open shows the game above the
/// fold and every touch control below it.
///
/// Every figure here was read off the iPhone Duo simulator (iOS 27.1) on
/// 2026-11-13, with a probe that logged `UIHinge.status` and
/// `UIView.reservedRegions(kind: .division)` from the overlay through each
/// pose. The window is 669x951 pt both flat and half open in the rotated
/// pose, which is why none of this can be inferred from its size.
private enum Duo {
    /// Open and rotated: the fold runs from side to side.
    static let rotated = CGRect(x: 0, y: 0, width: 669, height: 951)
    /// Open as it unfolds from portrait: the fold runs from top to bottom.
    static let book = CGRect(x: 0, y: 0, width: 951, height: 669)
    static let insets = UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 0)

    /// 40 pt thick, margins included, centred on the fold.
    static let rotatedDivision = CGRect(x: 0, y: 455.5, width: 669, height: 40)
    static let bookDivision = CGRect(x: 455.5, y: 0, width: 40, height: 669)

    /// A 4:3 picture fitted in the 669x455.5 above the band, centred.
    static let confinedPicture = CGRect(x: 30.83, y: 0, width: 607.33, height: 455.5)

    static func split(hingePartiallyOpen: Bool = true, active: Bool = true,
                      bounds: CGRect = rotated, division: CGRect = rotatedDivision) -> HalfOpenSplit? {
        HalfOpenSplit(bounds: bounds, hingePartiallyOpen: hingePartiallyOpen,
                      divisions: [FoldDivision(frame: division, isActive: active)])
    }
}

final class HalfOpenSplitTests: XCTestCase {

    // MARK: When the layout applies

    func testHalfOpenWithTheFoldAcrossSplitsAtTheBand() throws {
        let split = try XCTUnwrap(Duo.split())
        XCTAssertEqual(split.pictureArea, CGRect(x: 0, y: 0, width: 669, height: 455.5))
        XCTAssertEqual(split.controlsArea, CGRect(x: 0, y: 495.5, width: 669, height: 455.5))
        XCTAssertEqual(split.crease, Duo.rotatedDivision)
    }

    /// Flat, the system still reports the band, inactive, and the hinge
    /// reads fully open. Closed, the hinge reads closed. Neither splits.
    func testFlatOrClosedDoesNotSplit() {
        XCTAssertNil(Duo.split(hingePartiallyOpen: false, active: false))
    }

    /// The band turns active about a third of a second after the hinge
    /// reads partly open. Until it does there is nowhere to split.
    func testHingePartlyOpenButBandNotYetActiveDoesNotSplit() {
        XCTAssertNil(Duo.split(hingePartiallyOpen: true, active: false))
    }

    /// On the way out the hinge reads open or closed while the band is still
    /// active for a frame. The hinge decides.
    func testBandStillActiveAfterTheHingeLeftHalfOpenDoesNotSplit() {
        XCTAssertNil(Duo.split(hingePartiallyOpen: false, active: true))
    }

    /// Held like a book the hinge reads the same and the band is as active,
    /// but it runs from top to bottom: there is no upper half to stand the
    /// picture on.
    func testHalfOpenWithTheFoldDownTheMiddleDoesNotSplit() {
        XCTAssertNil(Duo.split(bounds: Duo.book, division: Duo.bookDivision))
    }

    /// A band that stops short of either side does not part the window in
    /// two, wherever it is. The Duo never reports one; this is the rule that
    /// would have to answer if something did.
    func testBandThatDoesNotCrossTheWindowDoesNotSplit() {
        XCTAssertNil(Duo.split(division: CGRect(x: 0, y: 455.5, width: 400, height: 40)))
        XCTAssertNil(Duo.split(division: CGRect(x: 269, y: 455.5, width: 400, height: 40)))
    }

    func testNoDivisionDoesNotSplit() {
        XCTAssertNil(HalfOpenSplit(bounds: Duo.rotated, hingePartiallyOpen: true, divisions: []))
    }

    /// A band hard against an edge would leave a sliver on one side.
    func testBandNearAnEdgeDoesNotSplit() {
        let high = CGRect(x: 0, y: 100, width: 669, height: 40)
        let low = CGRect(x: 0, y: 800, width: 669, height: 40)
        XCTAssertNil(Duo.split(division: high))
        XCTAssertNil(Duo.split(division: low))
    }

    /// The first active band across the window is the one used, whatever
    /// else is reported beside it.
    func testInactiveAndUprightBandsAreSkipped() throws {
        let split = try XCTUnwrap(HalfOpenSplit(
            bounds: Duo.rotated, hingePartiallyOpen: true,
            divisions: [FoldDivision(frame: CGRect(x: 0, y: 300, width: 669, height: 40), isActive: false),
                        FoldDivision(frame: CGRect(x: 300, y: 0, width: 40, height: 951), isActive: true),
                        FoldDivision(frame: Duo.rotatedDivision, isActive: true)]))
        XCTAssertEqual(split.crease, Duo.rotatedDivision)
    }
}

final class HalfOpenOverlayLayoutTests: XCTestCase {

    private func splitLayout(hudReserve: CGFloat = 0,
                             overrides: TouchOverlayLayoutOverrides = .none) throws -> (TouchOverlayLayout, HalfOpenSplit) {
        let split = try XCTUnwrap(Duo.split())
        let layout = TouchOverlayLayout(bounds: Duo.rotated, safeAreaInsets: Duo.insets,
                                        hudReserve: hudReserve, overrides: overrides,
                                        pictureRect: Duo.confinedPicture,
                                        controlsArea: split.controlsArea)
        return (layout, split)
    }

    /// The same window flat: the picture letterboxed in the middle of it.
    private var flatLayout: TouchOverlayLayout {
        TouchOverlayLayout(bounds: Duo.rotated, safeAreaInsets: Duo.insets, hudReserve: 0,
                           pictureRect: CGRect(x: 0, y: 224.625, width: 669, height: 501.75))
    }

    /// The definition of done, as written: every control in the lower half,
    /// none within the crease's margin.
    func testEveryControlIsBelowTheBand() throws {
        let (layout, split) = try splitLayout()
        let usable = Duo.rotated.inset(by: Duo.insets)
        for control in TouchOverlayControl.allCases {
            let frame = layout.frame(for: control)
            XCTAssertGreaterThanOrEqual(frame.minY, split.controlsArea.minY, "\(control) reaches above the fold's margin")
            XCTAssertFalse(frame.intersects(split.crease), "\(control) is on the crease")
            XCTAssertTrue(usable.contains(frame), "\(control) left the window: \(frame)")
        }
    }

    /// Flat, MAP and the menu button are in the top corners, above where the
    /// fold will be. This is the half of the arrangement the split moves, and
    /// what makes the case above mean something.
    func testFlatLayoutHasControlsAboveTheBand() {
        let flat = flatLayout
        XCTAssertLessThan(flat.frame(for: .automap).maxY, Duo.rotatedDivision.minY)
        XCTAssertLessThan(flat.frame(for: .menu).maxY, Duo.rotatedDivision.minY)
    }

    /// Apple's condition for a pose-specific layout: the same controls. The
    /// split moves them; it does not resize them.
    func testControlsKeepTheirSizes() throws {
        let (layout, _) = try splitLayout()
        let flat = flatLayout
        XCTAssertEqual(layout.scale, flat.scale)
        XCTAssertEqual(layout.stickRadius, flat.stickRadius)
        for control in TouchOverlayControl.allCases {
            XCTAssertEqual(layout.frame(for: control).size, flat.frame(for: control).size, "\(control)")
        }
    }

    /// MAP stays in the left corner and the menu button in the right, now
    /// the corners of the lower half.
    func testTopRowStandsAtTheTopOfTheLowerHalf() throws {
        let (layout, split) = try splitLayout()
        let flat = flatLayout
        let map = layout.frame(for: .automap), menu = layout.frame(for: .menu)
        XCTAssertEqual(map.midX, flat.frame(for: .automap).midX)
        XCTAssertEqual(menu.midX, flat.frame(for: .menu).midX)
        XCTAssertEqual(map.midY, split.controlsArea.minY + 32 * layout.scale, accuracy: 0.001)
        XCTAssertEqual(menu.midY, map.midY)
    }

    /// The Yes/No pair follows the top row down.
    func testPromptButtonsAreBelowTheBand() throws {
        let (layout, split) = try splitLayout()
        let prompt = layout.promptButtonFrames()
        for frame in [prompt.no, prompt.yes] {
            XCTAssertGreaterThanOrEqual(frame.minY, split.controlsArea.minY)
            XCTAssertFalse(frame.intersects(split.crease))
        }
    }

    /// The bar is up in the picture, so the cluster stands on the line it
    /// uses in any window whose picture is clear of it, and keeps its shape.
    func testBottomClusterClearsTheConfinedPictureAndKeepsItsShape() throws {
        let (layout, _) = try splitLayout()
        let flat = flatLayout
        for control in [TouchOverlayControl.fire, .use, .weaponPrev, .weaponNext] {
            XCTAssertFalse(layout.frame(for: control).intersects(Duo.confinedPicture), "\(control)")
        }
        let fire = layout.frame(for: .fire), flatFire = flat.frame(for: .fire)
        for control in [TouchOverlayControl.use, .weaponPrev, .weaponNext] {
            let offset = CGPoint(x: layout.frame(for: control).midX - fire.midX,
                                 y: layout.frame(for: control).midY - fire.midY)
            let flatOffset = CGPoint(x: flat.frame(for: control).midX - flatFire.midX,
                                     y: flat.frame(for: control).midY - flatFire.midY)
            XCTAssertEqual(offset.x, flatOffset.x, accuracy: 0.001, "\(control)")
            XCTAssertEqual(offset.y, flatOffset.y, accuracy: 0.001, "\(control)")
        }
    }

    /// A position the player saved flat, far up the window, is held below
    /// the band while the device is half open.
    func testAPlayersOwnPositionIsHeldBelowTheBand() throws {
        var overrides = TouchOverlayLayoutOverrides.none
        overrides[.fire] = CGPoint(x: 0, y: -900)
        overrides[.automap] = CGPoint(x: 0, y: -200)
        let (layout, split) = try splitLayout(overrides: overrides)
        for control in [TouchOverlayControl.fire, .automap] {
            XCTAssertEqual(layout.frame(for: control).minY, split.controlsArea.minY, accuracy: 0.001, "\(control)")
        }
    }

    /// The debug strip stays at the top of the window, on the picture. It
    /// must not push the lower half's top row down as it does a whole
    /// window's.
    func testDebugStripAboveTheFoldDoesNotMoveTheLowerHalf() throws {
        let (plain, _) = try splitLayout()
        let (withStrip, _) = try splitLayout(hudReserve: 60)
        for control in TouchOverlayControl.allCases {
            XCTAssertEqual(withStrip.frame(for: control), plain.frame(for: control), "\(control)")
        }
    }

    /// No area, no change: the parameter's default is the layout every other
    /// test in this target pins.
    func testWithoutAnAreaNothingMoves() {
        let flat = flatLayout
        let explicit = TouchOverlayLayout(bounds: Duo.rotated, safeAreaInsets: Duo.insets, hudReserve: 0,
                                          pictureRect: CGRect(x: 0, y: 224.625, width: 669, height: 501.75),
                                          controlsArea: nil)
        for control in TouchOverlayControl.allCases {
            XCTAssertEqual(explicit.frame(for: control), flat.frame(for: control), "\(control)")
        }
    }
}

final class HalfOpenTrackRouterTests: XCTestCase {

    private func router(_ scheme: TouchControlScheme, controlsArea: CGRect?) -> TouchTrackRouter {
        TouchTrackRouter(overlayWidth: Duo.rotated.width, scheme: scheme, buttons: [],
                         controlsArea: controlsArea)
    }

    private let lowerHalf = CGRect(x: 0, y: 495.5, width: 669, height: 455.5)

    /// The stick and the drag-to-turn surface are controls too: a finger on
    /// the picture, or on the band, starts neither.
    func testNoTrackStartsAboveTheLowerHalf() {
        for scheme in TouchControlScheme.allCases {
            let router = router(scheme, controlsArea: lowerHalf)
            for y in [10.0, 300.0, 455.5, 475.0, 495.0] {
                for x in [50.0, 600.0] {
                    XCTAssertEqual(router.route(CGPoint(x: x, y: y), stickTracking: false, turnTracking: false),
                                   .ignore, "\(scheme) at \(x),\(y)")
                }
            }
        }
    }

    func testTracksStartInTheLowerHalfAsEverywhereElse() {
        let modern = router(.modern, controlsArea: lowerHalf)
        XCTAssertEqual(modern.route(CGPoint(x: 50, y: 700), stickTracking: false, turnTracking: false), .stick)
        XCTAssertEqual(modern.route(CGPoint(x: 600, y: 700), stickTracking: false, turnTracking: false), .turn)
    }

    /// The same points with no split, so the first case is the area's doing.
    func testWithoutAnAreaThePictureStartsTracks() {
        let modern = router(.modern, controlsArea: nil)
        XCTAssertEqual(modern.route(CGPoint(x: 50, y: 300), stickTracking: false, turnTracking: false), .stick)
        XCTAssertEqual(modern.route(CGPoint(x: 600, y: 300), stickTracking: false, turnTracking: false), .turn)
    }

    /// A menu on the picture is still tapped on the picture: a touch the
    /// track router ignores is the menu's pointer when a menu is up.
    func testAMenuAboveTheFoldIsStillTappedWhereItIs() {
        let route = router(.modern, controlsArea: lowerHalf)
            .route(CGPoint(x: 50, y: 300), stickTracking: false, turnTracking: false)
        XCTAssertEqual(MenuTouchRouter().began(menuActive: true, trackRoute: route,
                                               nearButton: false, pointerOwned: false), .pointer)
    }
}
