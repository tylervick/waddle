import UIKit
import XCTest
@testable import Waddle

/// Issue #351: the bottom cluster against the status bar the engine is
/// actually drawing, not a band assumed along the window's bottom edge.
///
/// `TouchOverlayLayoutTests.testBottomClusterClearsTheStatusBarReserve` holds
/// the cluster above `rect.maxY - statusBarReserve`, which is the same
/// window-bottom assumption the layout made, so it could not see the weapon
/// pair sitting on the bar in a letterboxed window close to square. These
/// cases hand the layout the picture rect and check the cluster against the
/// bar inside it.
final class TouchOverlayLayoutStatusBarTests: XCTestCase {

    private static let cluster: [TouchOverlayControl] = [.fire, .use, .weaponPrev, .weaponNext]

    private struct Shape {
        let name: String
        let window: CGRect
        let picture: CGRect
    }

    /// The two iPhone Duo poses that letterbox, with the picture as measured
    /// on the simulator on 2026-11-09 (the issue's table). The closed one is
    /// deliberately not 4:3: that session started on the open display and the
    /// engine kept 1.42:1 after the fold, which is why the rect has to come
    /// from the engine and cannot be derived from the window.
    ///
    /// The third is an iPad in portrait, which the issue did not list: the
    /// same arithmetic puts a centred 4:3 picture's bar under the weapon pair
    /// there too, so it is fixed by the same rule and held to the same cases.
    private static let letterboxed: [Shape] = [
        Shape(name: "iPad Pro 13 portrait",
              window: CGRect(x: 0, y: 0, width: 1032, height: 1376),
              picture: CGRect(x: 0, y: 301, width: 1032, height: 774)),
        Shape(name: "iPhone Duo closed, portrait",
              window: CGRect(x: 0, y: 0, width: 466, height: 678),
              picture: CGRect(x: 0, y: 171, width: 466, height: 329)),
        Shape(name: "iPhone Duo open, rotated",
              window: CGRect(x: 0, y: 0, width: 669, height: 951),
              picture: CGRect(x: 0, y: 245, width: 669, height: 469)),
    ]

    /// Windows where today's arrangement is already right and must not move.
    private static let unmoved: [Shape] = [
        Shape(name: "iPhone 17 Pro portrait",
              window: CGRect(x: 0, y: 0, width: 402, height: 874),
              picture: CGRect(x: 0, y: 286.25, width: 402, height: 301.5)),
        Shape(name: "iPhone 17 Pro landscape",
              window: CGRect(x: 0, y: 0, width: 874, height: 402),
              picture: CGRect(x: 0, y: 0, width: 874, height: 402)),
        Shape(name: "iPhone Duo open",
              window: CGRect(x: 0, y: 0, width: 951, height: 669),
              picture: CGRect(x: 0, y: 0, width: 951, height: 669)),
        Shape(name: "iPhone Duo closed, landscape",
              window: CGRect(x: 0, y: 0, width: 678, height: 466),
              picture: CGRect(x: 0, y: 0, width: 678, height: 466)),
        Shape(name: "iPad Pro 13 landscape",
              window: CGRect(x: 0, y: 0, width: 1376, height: 1032),
              picture: CGRect(x: 0, y: 0, width: 1376, height: 1032)),
    ]

    private func layout(_ shape: Shape, usingPicture: Bool = true) -> TouchOverlayLayout {
        TouchOverlayLayout(bounds: shape.window, safeAreaInsets: .zero, hudReserve: 0,
                           pictureRect: usingPicture ? shape.picture : nil)
    }

    /// The bar as the engine draws it: the bottom 32 of the picture's 200 rows.
    private func bar(of picture: CGRect) -> CGRect {
        let height = picture.height * 32 / 200
        return CGRect(x: picture.minX, y: picture.maxY - height, width: picture.width, height: height)
    }

    // MARK: The defect and its fix

    /// The discrimination proof, kept in the suite: with the picture rect
    /// ignored, which is the layout as it shipped, the weapon pair is on the
    /// bar in each of them. If this ever stops failing-by-design, the cases
    /// below have stopped measuring the thing the issue was about.
    func testWithoutThePictureRectTheWeaponPairSitsOnTheBar() {
        for shape in Self.letterboxed {
            let old = layout(shape, usingPicture: false)
            let bar = bar(of: shape.picture)
            for control in [TouchOverlayControl.weaponPrev, .weaponNext] {
                XCTAssertTrue(TouchOverlayLayout.overlaps(old.frame(for: control), bar),
                              "\(control.rawValue) was expected on the bar on \(shape.name): "
                              + "\(old.frame(for: control)) vs \(bar)")
            }
        }
    }

    func testNoDefaultControlOverlapsTheBarInALetterboxedWindow() {
        for shape in Self.letterboxed {
            let l = layout(shape)
            let bar = bar(of: shape.picture)
            for control in TouchOverlayControl.allCases {
                XCTAssertFalse(TouchOverlayLayout.overlaps(l.frame(for: control), bar),
                               "\(control.rawValue) at \(l.frame(for: control)) is on the status bar "
                               + "\(bar) on \(shape.name)")
            }
        }
    }

    /// All three have room under the picture, so the cluster goes there and
    /// stays out of the game entirely, inside the window and still a cluster.
    func testTheClusterMovesBelowThePictureAndStaysInTheWindow() {
        for shape in Self.letterboxed {
            let l = layout(shape)
            for control in Self.cluster {
                let frame = l.frame(for: control)
                XCTAssertGreaterThanOrEqual(frame.minY, shape.picture.maxY,
                                            "\(control.rawValue) is not below the picture on \(shape.name)")
                XCTAssertTrue(shape.window.contains(frame),
                              "\(control.rawValue) left the window on \(shape.name): \(frame)")
            }
            let fire = l.frame(for: .fire)
            for weapon in [TouchOverlayControl.weaponPrev, .weaponNext] {
                let frame = l.frame(for: weapon)
                let dx = frame.midX - fire.midX, dy = frame.midY - fire.midY
                XCTAssertLessThan((dx * dx + dy * dy).squareRoot(), 150 * l.scale,
                                  "\(weapon.rawValue) is no longer clustered with FIRE on \(shape.name)")
            }
        }
    }

    /// The band the layout reports is the one the engine draws, so the
    /// layout editor's placeholder lands where the bar will be.
    func testTheReportedBandIsTheBottomSixteenPercentOfThePicture() {
        for shape in Self.letterboxed + Self.unmoved {
            let band = layout(shape).statusBarBand
            let expected = bar(of: shape.picture)
            XCTAssertEqual(band.minX, expected.minX, accuracy: 0.001, shape.name)
            XCTAssertEqual(band.minY, expected.minY, accuracy: 0.001, shape.name)
            XCTAssertEqual(band.width, expected.width, accuracy: 0.001, shape.name)
            XCTAssertEqual(band.height, expected.height, accuracy: 0.001, shape.name)
        }
    }

    // MARK: What must not move

    /// Phones in both orientations, and any window the picture fills, keep
    /// the arrangement they were tuned with: knowing where the picture is
    /// changes nothing there.
    func testLayoutsThatWereAlreadyClearDoNotMove() {
        for shape in Self.unmoved {
            let with = layout(shape), without = layout(shape, usingPicture: false)
            for control in TouchOverlayControl.allCases {
                XCTAssertEqual(with.frame(for: control), without.frame(for: control),
                               "\(control.rawValue) moved on \(shape.name)")
            }
        }
    }

    /// Where the picture fills the window the cluster is over the 3D view,
    /// which is allowed, and still clear of the bar itself.
    func testAFilledWindowKeepsTheClusterOverTheViewAndOffTheBar() {
        for shape in Self.unmoved where shape.picture == shape.window {
            let l = layout(shape)
            let bar = bar(of: shape.picture)
            for control in Self.cluster {
                let frame = l.frame(for: control)
                XCTAssertTrue(shape.picture.contains(frame),
                              "\(control.rawValue) is not over the picture on \(shape.name)")
                XCTAssertFalse(TouchOverlayLayout.overlaps(frame, bar),
                               "\(control.rawValue) is on the status bar on \(shape.name)")
            }
        }
    }

    // MARK: The other branch

    /// A letterboxed window with no room under the picture: the cluster
    /// cannot go below, so it goes above the bar, over the 3D view.
    func testWithNoRoomBelowThePictureTheClusterGoesAboveTheBar() {
        let shape = Shape(name: "short letterbox",
                          window: CGRect(x: 0, y: 0, width: 600, height: 500),
                          picture: CGRect(x: 0, y: 25, width: 600, height: 450))
        let bar = bar(of: shape.picture)
        let old = layout(shape, usingPicture: false)
        XCTAssertTrue(Self.cluster.contains { TouchOverlayLayout.overlaps(old.frame(for: $0), bar) },
                      "this shape is meant to collide before the fix")

        let l = layout(shape)
        for control in Self.cluster {
            let frame = l.frame(for: control)
            XCTAssertLessThanOrEqual(frame.maxY, bar.minY + 0.001,
                                     "\(control.rawValue) is not above the bar: \(frame) vs \(bar)")
            XCTAssertTrue(shape.window.contains(frame), "\(control.rawValue) left the window")
        }
    }

    /// A player's saved offset rides on the default, so a moved control
    /// follows the cluster rather than being left behind on the bar.
    func testAnOverrideIsAppliedFromTheMovedDefault() {
        let shape = Self.letterboxed[2]
        let plain = layout(shape)
        var overrides = TouchOverlayLayoutOverrides.none
        overrides[.weaponPrev] = CGPoint(x: -20, y: 0)
        let moved = TouchOverlayLayout(bounds: shape.window, safeAreaInsets: .zero, hudReserve: 0,
                                       overrides: overrides, pictureRect: shape.picture)
        XCTAssertEqual(moved.frame(for: .weaponPrev).midX,
                       plain.frame(for: .weaponPrev).midX - 20 * plain.scale, accuracy: 0.001)
        XCTAssertEqual(moved.frame(for: .weaponPrev).midY,
                       plain.frame(for: .weaponPrev).midY, accuracy: 0.001)
    }

    // MARK: The prediction

    /// What the editor and a session's first quarter second assume. A window
    /// the engine can fill is filled; a taller one gets a centred 4:3.
    func testThePredictedPictureFillsWideWindowsAndLetterboxesTallOnes() {
        let wide = CGRect(x: 0, y: 0, width: 951, height: 669)
        XCTAssertEqual(TouchOverlayLayout.predictedPictureRect(in: wide), wide)

        let tall = CGRect(x: 0, y: 0, width: 466, height: 678)
        let predicted = TouchOverlayLayout.predictedPictureRect(in: tall)
        XCTAssertEqual(predicted.width, 466, accuracy: 0.001)
        XCTAssertEqual(predicted.height, 349.5, accuracy: 0.001)
        XCTAssertEqual(predicted.midY, tall.midY, accuracy: 0.001)

        // Wider than the engine renders: pillarboxed at 3.6:1.
        let ribbon = CGRect(x: 0, y: 0, width: 2000, height: 400)
        let pillar = TouchOverlayLayout.predictedPictureRect(in: ribbon)
        XCTAssertEqual(pillar.height, 400, accuracy: 0.001)
        XCTAssertEqual(pillar.width, 1440, accuracy: 0.001)
        XCTAssertEqual(pillar.midX, ribbon.midX, accuracy: 0.001)
    }

    /// The prediction must leave phones alone too, since it is what a
    /// session lays out with before the engine has a window.
    func testThePredictionDoesNotMoveAPhone() {
        for window in [CGRect(x: 0, y: 0, width: 402, height: 874),
                       CGRect(x: 0, y: 0, width: 874, height: 402),
                       CGRect(x: 0, y: 0, width: 360, height: 780),
                       CGRect(x: 0, y: 0, width: 440, height: 956)] {
            let predicted = TouchOverlayLayout(
                bounds: window, safeAreaInsets: .zero, hudReserve: 0,
                pictureRect: TouchOverlayLayout.predictedPictureRect(in: window))
            let plain = TouchOverlayLayout(bounds: window, safeAreaInsets: .zero, hudReserve: 0)
            for control in TouchOverlayControl.allCases {
                XCTAssertEqual(predicted.frame(for: control), plain.frame(for: control),
                               "\(control.rawValue) moved in \(window)")
            }
        }
    }
}
