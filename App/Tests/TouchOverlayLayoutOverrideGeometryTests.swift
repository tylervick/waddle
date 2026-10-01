import UIKit
import XCTest
@testable import Waddle

/// How a user's offsets change the overlay geometry (issue #115). Offsets
/// are in reference points (scale 1.0) and move the control's center from
/// its default by `offset * scale`, so a layout a player arranged on a phone
/// keeps its shape on an iPad the way the defaults do. Whatever the offset,
/// the control stays inside the window: the clamp is the same containment
/// property `TouchOverlayLayoutTests.testEveryControlStaysInsideBounds`
/// asserts for the defaults, extended to every position a user can persist.
final class TouchOverlayLayoutOverrideGeometryTests: XCTestCase {
    private static let allBounds: [(name: String, rect: CGRect)] = [
        ("iPhone 17 Pro portrait", CGRect(x: 0, y: 0, width: 402, height: 874)),
        ("iPhone 17 Pro landscape", CGRect(x: 0, y: 0, width: 874, height: 402)),
        ("iPad Pro 13 landscape", CGRect(x: 0, y: 0, width: 1376, height: 1032)),
        ("iPad Pro 11 landscape", CGRect(x: 0, y: 0, width: 1210, height: 834)),
        ("tiny window", CGRect(x: 0, y: 0, width: 573, height: 545)),
    ]
    private static let phoneLandscape = CGRect(x: 0, y: 0, width: 874, height: 402)
    private static let iPadLandscape = CGRect(x: 0, y: 0, width: 1376, height: 1032)

    private func layout(_ bounds: CGRect, insets: UIEdgeInsets = .zero, hudReserve: CGFloat = 0,
                        overrides: TouchOverlayLayoutOverrides = .none) -> TouchOverlayLayout {
        TouchOverlayLayout(bounds: bounds, safeAreaInsets: insets, hudReserve: hudReserve,
                           overrides: overrides)
    }

    /// No overrides means the shipped geometry, frame for frame. Existing
    /// callers pass nothing and must see nothing change.
    func testEmptyOverridesReproduceTheDefaultFrames() {
        for (name, rect) in Self.allBounds {
            let plain = layout(rect)
            let withEmpty = layout(rect, overrides: .none)
            for control in TouchOverlayControl.allCases {
                XCTAssertEqual(plain.frame(for: control), withEmpty.frame(for: control), name)
                XCTAssertEqual(plain.defaultFrame(for: control), plain.frame(for: control), name)
            }
        }
    }

    /// An offset moves the center by exactly offset * scale and leaves the
    /// size alone. On the reference device scale is 1.0, so the numbers are
    /// literal.
    func testOffsetMovesTheCenterByScaledPoints() {
        var overrides = TouchOverlayLayoutOverrides.none
        overrides[.use] = CGPoint(x: -100, y: -60)
        let phone = layout(Self.phoneLandscape, overrides: overrides)
        let defaultFrame = phone.defaultFrame(for: .use)
        let moved = phone.frame(for: .use)
        XCTAssertEqual(moved.midX, defaultFrame.midX - 100, accuracy: 0.001)
        XCTAssertEqual(moved.midY, defaultFrame.midY - 60, accuracy: 0.001)
        XCTAssertEqual(moved.size, defaultFrame.size)

        // On the iPad the same stored offset covers scale-times the points,
        // so the arrangement keeps its proportions like the defaults do.
        let pad = layout(Self.iPadLandscape, overrides: overrides)
        let s = pad.scale
        XCTAssertGreaterThan(s, 1.5)
        XCTAssertEqual(pad.frame(for: .use).midX, pad.defaultFrame(for: .use).midX - 100 * s, accuracy: 0.01)
        XCTAssertEqual(pad.frame(for: .use).midY, pad.defaultFrame(for: .use).midY - 60 * s, accuracy: 0.01)
    }

    /// A control the user did not move is untouched by the others' offsets.
    func testUnmovedControlsKeepTheirDefaults() {
        var overrides = TouchOverlayLayoutOverrides.none
        overrides[.fire] = CGPoint(x: -300, y: -100)
        let l = layout(Self.phoneLandscape, overrides: overrides)
        for control in TouchOverlayControl.allCases where control != .fire {
            XCTAssertEqual(l.frame(for: control), l.defaultFrame(for: control), control.rawValue)
        }
    }

    /// The clamp, which is the issue's hard requirement: a persisted position
    /// outside the current window (saved in landscape, installed in portrait;
    /// saved on an iPad, installed in a small window) lands inside it. Every
    /// control, every shape, offsets far past every edge in every direction.
    func testWildOffsetsAreClampedInsideTheWindow() {
        let wild: [CGPoint] = [
            CGPoint(x: -5000, y: 0), CGPoint(x: 5000, y: 0),
            CGPoint(x: 0, y: -5000), CGPoint(x: 0, y: 5000),
            CGPoint(x: -5000, y: -5000), CGPoint(x: 5000, y: 5000),
        ]
        for (name, rect) in Self.allBounds {
            for offset in wild {
                var overrides = TouchOverlayLayoutOverrides.none
                for control in TouchOverlayControl.allCases { overrides[control] = offset }
                let l = layout(rect, overrides: overrides)
                for control in TouchOverlayControl.allCases {
                    let frame = l.frame(for: control)
                    XCTAssertTrue(rect.contains(frame),
                                  "\(control.rawValue) escaped \(name) with offset \(offset): \(frame)")
                    XCTAssertEqual(frame.size, l.defaultFrame(for: control).size,
                                   "clamping must move the control, never resize it")
                }
            }
        }
    }

    /// The clamp respects the safe area and the debug-HUD strip like the
    /// defaults do: a control dragged into the notch band or under the strip
    /// is pushed back out.
    func testClampRespectsSafeAreaAndHudReserve() {
        let insets = UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59) // iPhone 17 Pro landscape
        var overrides = TouchOverlayLayoutOverrides.none
        overrides[.automap] = CGPoint(x: -5000, y: -5000)
        overrides[.fire] = CGPoint(x: 5000, y: 5000)
        let l = layout(Self.phoneLandscape, insets: insets, hudReserve: 60, overrides: overrides)
        let usable = Self.phoneLandscape.inset(by: insets)
        let map = l.frame(for: .automap)
        XCTAssertGreaterThanOrEqual(map.minX, usable.minX - 0.001)
        XCTAssertGreaterThanOrEqual(map.minY, usable.minY + 60 - 0.001, "pushed under the HUD strip")
        let fire = l.frame(for: .fire)
        XCTAssertLessThanOrEqual(fire.maxX, usable.maxX + 0.001)
        XCTAssertLessThanOrEqual(fire.maxY, usable.maxY + 0.001)
    }

    /// The editor's drag math: asking for a center returns the offset that
    /// puts the control there, already clamped, so what the editor stores is
    /// what the player saw. Round-tripping it through `frame(for:)` lands on
    /// the clamped center.
    func testClampedOverrideOffsetRoundTripsThroughFrame() {
        let l = layout(Self.phoneLandscape)
        // In range: the exact point comes back.
        let target = CGPoint(x: 300, y: 200)
        let offset = l.clampedOverrideOffset(placing: .fire, at: target)
        var overrides = TouchOverlayLayoutOverrides.none
        overrides[.fire] = offset
        let placed = layout(Self.phoneLandscape, overrides: overrides).frame(for: .fire)
        XCTAssertEqual(placed.midX, target.x, accuracy: 0.001)
        XCTAssertEqual(placed.midY, target.y, accuracy: 0.001)

        // Out of range: the offset is for the clamped center, not the finger.
        let outside = CGPoint(x: -400, y: 9999)
        var clampedOverrides = TouchOverlayLayoutOverrides.none
        clampedOverrides[.fire] = l.clampedOverrideOffset(placing: .fire, at: outside)
        let clamped = layout(Self.phoneLandscape, overrides: clampedOverrides).frame(for: .fire)
        XCTAssertTrue(Self.phoneLandscape.contains(clamped), "\(clamped)")
        XCTAssertEqual(clamped.minX, 0, accuracy: 0.001, "pinned to the left edge")
        XCTAssertEqual(clamped.maxY, Self.phoneLandscape.maxY, accuracy: 0.001, "pinned to the bottom edge")
    }

    /// Placing a control exactly at its default center stores a zero offset,
    /// so "dragged back to where it was" and "never moved" are the same
    /// persisted state.
    func testPlacingAtTheDefaultCenterIsAZeroOffset() {
        let l = layout(Self.phoneLandscape)
        let center = CGPoint(x: l.defaultFrame(for: .menu).midX, y: l.defaultFrame(for: .menu).midY)
        let offset = l.clampedOverrideOffset(placing: .menu, at: center)
        XCTAssertEqual(offset.x, 0, accuracy: 0.001)
        XCTAssertEqual(offset.y, 0, accuracy: 0.001)
    }
}
