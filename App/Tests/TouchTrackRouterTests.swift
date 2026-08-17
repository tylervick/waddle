import XCTest
@testable import Waddle

/// Routing coverage for `TouchTrackRouter` — the stick/turn/ignore decision
/// that used to live inline in `TouchOverlayView.touchesBegan`.
///
/// The live hazard these cases exist for is the `modern` scheme: its entire
/// right region is a drag-to-turn surface, so a fingertip that misses FIRE,
/// USE or a weapon button by a few points lands on bare overlay inside the
/// turn region, and only the near-miss cushion stops it swinging the view.
/// The one pre-existing test of the guard
/// (`TouchControlsTests.testNearMissBesideWeaponPrevDoesNotStartStick`) runs
/// the `classic` scheme in `WaddleUITests`, which the pull-request path never
/// runs, and cannot fail if the cushion regresses — `classic` starts no turn
/// track at all.
///
/// Button frames come from `TouchOverlayLayout` rather than from hand-written
/// rects, so these cases follow the shipped arrangement instead of a
/// second copy of it that can drift.
final class TouchTrackRouterTests: XCTestCase {
    /// iPhone 17 Pro portrait, from the CoreSimulator profile
    /// (1206x2622 px at scale 3), which is also `TouchOverlayLayout`'s
    /// reference device — so `scale` is exactly 1.0 and every frame below is
    /// the shipped phone geometry.
    private let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)

    private var layout: TouchOverlayLayout {
        TouchOverlayLayout(bounds: bounds, safeAreaInsets: .zero, hudReserve: 0)
    }

    private func frame(_ control: TouchOverlayControl) -> CGRect {
        layout.frame(for: control)
    }

    /// Every control visible, as the overlay has them during ordinary play.
    private var allVisible: [TouchOverlayButtonState] {
        TouchOverlayControl.allCases.map {
            TouchOverlayButtonState(frame: frame($0), isHidden: false)
        }
    }

    private func router(_ scheme: TouchControlScheme,
                        buttons: [TouchOverlayButtonState]? = nil,
                        margin: CGFloat = TouchTrackRouter.buttonNearMissMargin)
        -> TouchTrackRouter {
        TouchTrackRouter(overlayWidth: bounds.width, scheme: scheme,
                         buttons: buttons ?? allVisible, nearMissMargin: margin)
    }

    // MARK: Near-miss points

    /// 10pt past an edge: outside the button's own frame, half way into the
    /// 20pt cushion. Directions are chosen per control so the point does not
    /// land inside a *neighbouring* button's frame — a point below
    /// weaponNext, for instance, is inside FIRE, and would then be rejected
    /// for the wrong reason. `testNearMissPointsAreGenuineNearMisses` below
    /// holds that property to account.
    private static let overshoot: CGFloat = 10

    private func justBelow(_ f: CGRect) -> CGPoint {
        CGPoint(x: f.midX, y: f.maxY + Self.overshoot)
    }

    private func justAbove(_ f: CGRect) -> CGPoint {
        CGPoint(x: f.midX, y: f.minY - Self.overshoot)
    }

    private func justLeft(_ f: CGRect) -> CGPoint {
        CGPoint(x: f.minX - Self.overshoot, y: f.midY)
    }

    /// The four right-hand-cluster buttons a thumb actually misses mid-play,
    /// each with a miss direction that clears its neighbours.
    private var rightSideNearMisses: [(name: String, point: CGPoint)] {
        [("FIRE", justBelow(frame(.fire))),
         ("USE", justLeft(frame(.use))),
         ("weaponPrev", justAbove(frame(.weaponPrev))),
         ("weaponNext", justAbove(frame(.weaponNext)))]
    }

    /// Bare overlay in the right region, clear of every button and its
    /// cushion.
    private var cleanRightPoint: CGPoint {
        CGPoint(x: bounds.width * 0.7, y: bounds.height * 0.35)
    }

    /// Bare overlay in the movement stick's own column.
    private var cleanLeftPoint: CGPoint {
        CGPoint(x: bounds.width * 0.2, y: bounds.height * 0.6)
    }

    // MARK: The points themselves are what the cases claim

    /// Guards every case below: each near-miss point must be *outside* every
    /// button's real frame (otherwise the button would have swallowed the
    /// touch and the router never sees it) and *inside* its own target's
    /// cushion (otherwise it is not a near miss at all). Without this, a
    /// layout change could quietly turn all four cases into assertions about
    /// nothing.
    func testNearMissPointsAreGenuineNearMisses() {
        let margin = TouchTrackRouter.buttonNearMissMargin
        for (name, point) in rightSideNearMisses {
            for control in TouchOverlayControl.allCases {
                XCTAssertFalse(frame(control).contains(point),
                    "\(name)'s near-miss point is inside \(control.rawValue)'s own frame")
            }
            XCTAssertTrue(bounds.contains(point), "\(name)'s near-miss point is off-screen")
            XCTAssertGreaterThanOrEqual(
                point.x, bounds.width * TouchTrackRouter.stickColumnFraction,
                "\(name)'s near-miss point is not in the right region")
        }
        let targets: [(String, TouchOverlayControl)] =
            [("FIRE", .fire), ("USE", .use),
             ("weaponPrev", .weaponPrev), ("weaponNext", .weaponNext)]
        for ((name, point), (_, control)) in zip(rightSideNearMisses, targets) {
            XCTAssertTrue(
                frame(control).insetBy(dx: -margin, dy: -margin).contains(point),
                "\(name)'s near-miss point is outside its own cushion")
        }
    }

    /// The control points must be clean overlay, or the cases that expect a
    /// track would be proving the opposite of what they claim.
    func testCleanPointsAreClearOfEveryButton() {
        let modern = router(.modern)
        XCTAssertFalse(modern.isNearButton(cleanRightPoint))
        XCTAssertFalse(modern.isNearButton(cleanLeftPoint))
        XCTAssertGreaterThanOrEqual(cleanRightPoint.x, modern.stickColumnLimit)
        XCTAssertLessThan(cleanLeftPoint.x, modern.stickColumnLimit)
    }

    // MARK: The hazard

    /// The case the issue exists for: in `modern`, a near-miss on any
    /// right-hand button must claim nothing rather than starting a turn
    /// track and swinging the player's view.
    func testModernNearMissOnRightSideButtonRoutesToNothing() {
        let modern = router(.modern)
        for (name, point) in rightSideNearMisses {
            XCTAssertEqual(
                modern.route(point, stickTracking: false, turnTracking: false), .ignore,
                "a near-miss beside \(name) started a track in the modern scheme")
        }
    }

    /// Control for the case above: without it, a router that rejected
    /// *everything* on the right would pass and prove nothing.
    func testModernCleanOverlayInRightRegionStartsTurnTrack() {
        XCTAssertEqual(
            router(.modern).route(cleanRightPoint, stickTracking: false, turnTracking: false),
            .turn)
    }

    /// The cushion is load-bearing, held permanently rather than by a manual
    /// experiment: with the margin at 0 the exact same four points become
    /// turn tracks. If this ever agrees with
    /// `testModernNearMissOnRightSideButtonRoutesToNothing`, that test has
    /// stopped covering the cushion.
    func testNearMissRejectionDependsOnTheCushion() {
        let unpadded = router(.modern, margin: 0)
        for (name, point) in rightSideNearMisses {
            XCTAssertEqual(
                unpadded.route(point, stickTracking: false, turnTracking: false), .turn,
                "\(name)'s near-miss point does not reach the turn region without the cushion, so the cushion is not what the case above is testing")
        }
        // The control point is unaffected by the margin, so the pair above
        // isolates the cushion rather than the region split.
        XCTAssertEqual(
            unpadded.route(cleanRightPoint, stickTracking: false, turnTracking: false), .turn)
    }

    // MARK: Scheme differences

    /// `classic` routes turning through the movement stick
    /// (`usesDragTurn == false`), so the right side is buttons only — clean
    /// overlay and near-misses alike claim nothing. This is why the existing
    /// classic-scheme UI test cannot fail when the cushion regresses.
    func testClassicNeverStartsATrackOnTheRight() {
        let classic = router(.classic)
        for (name, point) in rightSideNearMisses {
            XCTAssertEqual(
                classic.route(point, stickTracking: false, turnTracking: false), .ignore,
                "classic started a track on a near-miss beside \(name)")
        }
        XCTAssertEqual(
            classic.route(cleanRightPoint, stickTracking: false, turnTracking: false), .ignore,
            "classic started a turn track it has no gesture for")
    }

    /// The movement stick is scheme-independent: both schemes claim a clean
    /// touch in the left column.
    func testLeftColumnCleanOverlayStartsStickInBothSchemes() {
        for scheme in TouchControlScheme.allCases {
            XCTAssertEqual(
                router(scheme).route(cleanLeftPoint, stickTracking: false, turnTracking: false),
                .stick,
                "\(scheme.rawValue) did not start a stick track on clean overlay")
        }
    }

    // MARK: Hidden buttons

    /// `updateAutomapAvailability()` hides MAP whenever a menu is on screen.
    /// A hidden button accepts no touches, so the space it vacates must
    /// behave as ordinary overlay — the standing `nearButton(_:)` contract.
    /// MAP sits in the stick column, so the difference is visible as
    /// ignore-versus-stick on one single point.
    func testHiddenButtonClaimsNothing() {
        let point = justBelow(frame(.automap))
        XCTAssertLessThan(point.x, bounds.width * TouchTrackRouter.stickColumnFraction,
                          "MAP's near-miss point is not in the stick column")

        func buttons(automapHidden: Bool) -> [TouchOverlayButtonState] {
            TouchOverlayControl.allCases.map {
                TouchOverlayButtonState(frame: frame($0),
                                        isHidden: $0 == .automap && automapHidden)
            }
        }

        XCTAssertEqual(
            router(.modern, buttons: buttons(automapHidden: false))
                .route(point, stickTracking: false, turnTracking: false),
            .ignore,
            "a near-miss below a visible MAP was claimed as a stick track")
        XCTAssertEqual(
            router(.modern, buttons: buttons(automapHidden: true))
                .route(point, stickTracking: false, turnTracking: false),
            .stick,
            "the space a hidden MAP vacated is still refusing touches")
    }

    // MARK: Tracks already owned

    /// One finger per region: a second touch in a region whose track is
    /// already owned claims nothing rather than stealing it.
    func testRegionAlreadyTrackedClaimsNothing() {
        let modern = router(.modern)
        XCTAssertEqual(
            modern.route(cleanLeftPoint, stickTracking: true, turnTracking: false), .ignore)
        XCTAssertEqual(
            modern.route(cleanRightPoint, stickTracking: false, turnTracking: true), .ignore)
        // The two regions stay independent: an owned stick does not block a
        // turn track, and vice versa.
        XCTAssertEqual(
            modern.route(cleanRightPoint, stickTracking: true, turnTracking: false), .turn)
        XCTAssertEqual(
            modern.route(cleanLeftPoint, stickTracking: false, turnTracking: true), .stick)
    }

    /// The column split is taken from the overlay's width, so it follows a
    /// resize (iPadOS windowed multitasking) rather than pinning to whatever
    /// width the view had at install.
    func testStickColumnFollowsOverlayWidth() {
        let wide = TouchTrackRouter(overlayWidth: 1000, scheme: .modern, buttons: [])
        XCTAssertEqual(wide.stickColumnLimit, 400, accuracy: 0.0001)
        XCTAssertEqual(wide.route(CGPoint(x: 399, y: 500),
                                  stickTracking: false, turnTracking: false), .stick)
        XCTAssertEqual(wide.route(CGPoint(x: 400, y: 500),
                                  stickTracking: false, turnTracking: false), .turn)
    }
}
