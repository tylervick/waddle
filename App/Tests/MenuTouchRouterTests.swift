import XCTest
@testable import Waddle

/// The decision `TouchOverlayView.touchesBegan` makes while the engine's
/// menu is up: drive the menu pointer, wait and see (stick column), or
/// leave the touch alone. Pure, so the rule that keeps the stick usable for
/// menu navigation (DebugHUDInputTelemetryTests and the Revyl
/// menu-input-telemetry test drag it with the main menu open) is pinned
/// without UIKit.
final class MenuTouchRouterTests: XCTestCase {
    private let router = MenuTouchRouter()

    func testMenuTouchOutsideStickColumnDrivesThePointer() {
        XCTAssertEqual(router.began(menuActive: true, trackRoute: .ignore,
                                    nearButton: false, pointerOwned: false), .pointer)
        XCTAssertEqual(router.began(menuActive: true, trackRoute: .turn,
                                    nearButton: false, pointerOwned: false), .pointer)
    }

    func testMenuTouchInStickColumnIsPending() {
        XCTAssertEqual(router.began(menuActive: true, trackRoute: .stick,
                                    nearButton: false, pointerOwned: false), .pending)
    }

    func testSecondFingerIsIgnoredWhilePointerOwned() {
        XCTAssertEqual(router.began(menuActive: true, trackRoute: .ignore,
                                    nearButton: false, pointerOwned: true), .ignore)
    }

    func testNearMissOnAButtonIsIgnoredInMenus() {
        XCTAssertEqual(router.began(menuActive: true, trackRoute: .ignore,
                                    nearButton: true, pointerOwned: false), .ignore)
    }

    func testNoMenuPassesThroughToStickAndTurnRouting() {
        for route in [TouchTrackRoute.stick, .turn, .ignore] {
            XCTAssertEqual(router.began(menuActive: false, trackRoute: route,
                                        nearButton: false, pointerOwned: false), .passThrough)
        }
    }

    func testPendingTouchBecomesTheStickOnceItTravels() {
        let start = CGPoint(x: 80, y: 600)
        XCTAssertFalse(router.pendingBecameStick(from: start, to: CGPoint(x: 86, y: 606)))
        XCTAssertTrue(router.pendingBecameStick(from: start,
                                                to: CGPoint(x: 80, y: 600 + MenuTouchRouter.tapSlop + 1)))
    }

    func testPendingTouchLiftedInPlaceIsATap() {
        let start = CGPoint(x: 80, y: 600)
        XCTAssertEqual(router.ended(pendingFrom: start, at: CGPoint(x: 84, y: 597)), .tap)
        XCTAssertEqual(router.ended(pendingFrom: start, at: CGPoint(x: 80, y: 640)), .none)
    }
}
