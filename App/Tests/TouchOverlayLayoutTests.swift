import XCTest
@testable import WADdle

/// Device bounds used across these tests, in points, as
/// `CGRect(origin: .zero, size:)`. Sizes come from the CoreSimulator device
/// profiles (`mainScreenWidth`/`Height` / `mainScreenScale`), not from memory:
/// iPhone 17 Pro 1206x2622@3 = 402x874, iPad Pro 13" M4 2064x2752@2 =
/// 1032x1376, iPad Pro 11" M4 1668x2420@2 = 834x1210, iPhone 16e
/// 1170x2532@3 = 390x844.
private enum Bounds {
    static let iPhone17ProPortrait = CGRect(x: 0, y: 0, width: 402, height: 874)
    static let iPhone17ProLandscape = CGRect(x: 0, y: 0, width: 874, height: 402)
    static let iPhone16eLandscape = CGRect(x: 0, y: 0, width: 844, height: 390)
    static let iPadPro13Landscape = CGRect(x: 0, y: 0, width: 1376, height: 1032)
    static let iPadPro13Portrait = CGRect(x: 0, y: 0, width: 1032, height: 1376)
    static let iPadPro11Landscape = CGRect(x: 0, y: 0, width: 1210, height: 834)
    /// Issue #52's own estimate of where the old fixed-offset layout broke.
    static let tinyWindow = CGRect(x: 0, y: 0, width: 573, height: 545)
}

final class TouchOverlayLayoutScaleTests: XCTestCase {
    private func layout(_ bounds: CGRect) -> TouchOverlayLayout {
        TouchOverlayLayout(bounds: bounds, safeAreaInsets: .zero, hudReserve: 0)
    }

    /// The whole calibration rests on this: the reference device resolves to
    /// exactly 1.0, so every base offset in the layout table is literally the
    /// shipped iPhone geometry and no other device's number had to move to
    /// make this one land.
    func testReferenceDeviceScalesToExactlyOne() {
        XCTAssertEqual(layout(Bounds.iPhone17ProPortrait).scale, 1.0, accuracy: 0.0001)
    }

    /// Scale is derived from (short side, long side), not (width, height), so
    /// rotating the device must not resize the controls under the player's
    /// thumbs mid-session.
    func testScaleIsOrientationIndependent() {
        XCTAssertEqual(layout(Bounds.iPhone17ProPortrait).scale,
                       layout(Bounds.iPhone17ProLandscape).scale,
                       accuracy: 0.0001)
        XCTAssertEqual(layout(Bounds.iPadPro13Portrait).scale,
                       layout(Bounds.iPadPro13Landscape).scale,
                       accuracy: 0.0001)
        // Both sides being equal is satisfied by any constant, so pin that
        // the shared value is the real iPad one and not a degenerate default.
        XCTAssertGreaterThan(layout(Bounds.iPadPro13Portrait).scale, 1.0)
    }

    func testIPadScalesUp() {
        // min(1032/402, 1376/874) = min(2.567, 1.574)
        XCTAssertEqual(layout(Bounds.iPadPro13Landscape).scale, 1.574, accuracy: 0.001)
        // min(834/402, 1210/874) = min(2.075, 1.384)
        XCTAssertEqual(layout(Bounds.iPadPro11Landscape).scale, 1.384, accuracy: 0.001)
    }

    /// A smaller phone shrinks, but only just — this pins how small that
    /// change actually is, because "shipped iPhone layouts move" was the one
    /// risk worth bounding.
    func testSmallerPhoneShrinksOnlySlightly() {
        XCTAssertEqual(layout(Bounds.iPhone16eLandscape).scale, 0.966, accuracy: 0.001)
    }

    /// The iPadOS windowed-multitasking case from issue #52: the same factor
    /// that grows the overlay on iPad shrinks it here, which is what keeps
    /// the fixed offsets from walking off the edge.
    func testSmallWindowScalesDown() {
        let scale = layout(Bounds.tinyWindow).scale
        XCTAssertLessThan(scale, 1.0)
        // Shrinking, but nowhere near the floor — a bound that a degenerate
        // "always zero" or "always minScale" answer cannot satisfy.
        XCTAssertGreaterThan(scale, TouchOverlayLayout.minScale)
    }

    func testScaleIsClampedAtBothEnds() {
        let huge = layout(CGRect(x: 0, y: 0, width: 8000, height: 8000))
        XCTAssertEqual(huge.scale, TouchOverlayLayout.maxScale, accuracy: 0.0001)

        let sliver = layout(CGRect(x: 0, y: 0, width: 120, height: 90))
        XCTAssertEqual(sliver.scale, TouchOverlayLayout.minScale, accuracy: 0.0001)
    }

    /// Safe-area insets shrink the usable rect, so they must shrink the
    /// scale too — otherwise a device with large insets lays out as though
    /// it had room it does not have.
    func testScaleUsesTheSafeAreaInsetRect() {
        let inset = TouchOverlayLayout(
            bounds: Bounds.iPhone17ProLandscape,
            safeAreaInsets: UIEdgeInsets(top: 0, left: 60, bottom: 20, right: 60),
            hudReserve: 0)
        XCTAssertLessThan(inset.scale, 1.0)
        XCTAssertGreaterThan(inset.scale, TouchOverlayLayout.minScale)
    }
}

final class TouchOverlayLayoutGeometryTests: XCTestCase {
    /// Every shape the overlay can be asked to lay out in: both phone
    /// orientations, both iPad sizes, and the small multitasking window.
    private static let allBounds: [(name: String, rect: CGRect)] = [
        ("iPhone 17 Pro portrait", Bounds.iPhone17ProPortrait),
        ("iPhone 17 Pro landscape", Bounds.iPhone17ProLandscape),
        ("iPhone 16e landscape", Bounds.iPhone16eLandscape),
        ("iPad Pro 13 landscape", Bounds.iPadPro13Landscape),
        ("iPad Pro 13 portrait", Bounds.iPadPro13Portrait),
        ("iPad Pro 11 landscape", Bounds.iPadPro11Landscape),
        ("tiny window", Bounds.tinyWindow),
    ]

    private func layout(_ bounds: CGRect,
                        insets: UIEdgeInsets = .zero,
                        hudReserve: CGFloat = 0) -> TouchOverlayLayout {
        TouchOverlayLayout(bounds: bounds, safeAreaInsets: insets, hudReserve: hudReserve)
    }

    /// Issue #52: the old fixed offsets pushed button centers outside
    /// `bounds` once the window got small enough. Nothing may leave the
    /// usable rect at any size the window can reach.
    func testEveryControlStaysInsideBounds() {
        for (name, rect) in Self.allBounds {
            let l = layout(rect)
            for control in TouchOverlayControl.allCases {
                let frame = l.frame(for: control)
                XCTAssertTrue(rect.contains(frame),
                              "\(control.rawValue) escaped bounds on \(name): \(frame) vs \(rect)")
            }
        }
    }

    /// The other half of #52: shrinking must not pile controls on top of
    /// each other, or a tap lands on two buttons at once.
    func testControlsNeverOverlap() {
        for (name, rect) in Self.allBounds {
            let l = layout(rect)
            let controls = TouchOverlayControl.allCases
            for (i, a) in controls.enumerated() {
                for b in controls[(i + 1)...] {
                    XCTAssertFalse(l.frame(for: a).intersects(l.frame(for: b)),
                                   "\(a.rawValue) overlaps \(b.rawValue) on \(name)")
                }
            }
        }
    }

    /// The arrangement change: weapon switching happens mid-combat, so it
    /// belongs in the same thumb cluster as FIRE rather than pinned to the
    /// opposite top corners, where a 13" iPad makes it a two-handed reach.
    func testWeaponButtonsClusterWithFire() {
        for (name, rect) in Self.allBounds {
            let l = layout(rect)
            let fire = l.frame(for: .fire)
            for weapon in [TouchOverlayControl.weaponPrev, .weaponNext] {
                let frame = l.frame(for: weapon)
                XCTAssertGreaterThan(frame.midX, rect.midX,
                                     "\(weapon.rawValue) is not on the right half on \(name)")
                XCTAssertGreaterThan(frame.midY, rect.midY,
                                     "\(weapon.rawValue) is not in the lower half on \(name)")
                let dx = frame.midX - fire.midX, dy = frame.midY - fire.midY
                XCTAssertLessThan((dx * dx + dy * dy).squareRoot(), 150 * l.scale,
                                  "\(weapon.rawValue) is not clustered with FIRE on \(name)")
            }
        }
    }

    /// MAP and MENU are deliberately *not* in the thumb cluster — they are
    /// pause-the-action controls, and the predecessor put them in the top
    /// corners for the same reason (DOOM-iOS `hud.c` scheme 0).
    func testMapAndMenuAnchorToOppositeTopCorners() {
        for (name, rect) in Self.allBounds {
            let l = layout(rect)
            let map = l.frame(for: .automap), menu = l.frame(for: .menu)
            XCTAssertLessThan(map.midX, rect.midX, "MAP is not on the left on \(name)")
            XCTAssertGreaterThan(menu.midX, rect.midX, "MENU is not on the right on \(name)")
            for (label, frame) in [("MAP", map), ("MENU", menu)] {
                XCTAssertLessThan(frame.midY, rect.midY,
                                  "\(label) is not in the top half on \(name)")
            }
        }
    }

    /// The bug visible in `docs/app-store/screenshots/ipad-13/05-ingame.png`:
    /// FIRE and USE sat on top of Doom's status bar. The predecessor
    /// reserved a band for exactly this (`BOTTOM = 320 - 44`, `hud.c:91`).
    func testBottomClusterClearsTheStatusBarReserve() {
        for (name, rect) in Self.allBounds {
            let l = layout(rect)
            XCTAssertGreaterThan(l.statusBarReserve, 0, "no reserve on \(name)")
            let floor = rect.maxY - l.statusBarReserve
            for control in [TouchOverlayControl.fire, .use, .weaponPrev, .weaponNext] {
                XCTAssertLessThanOrEqual(l.frame(for: control).maxY, floor + 0.001,
                                         "\(control.rawValue) intrudes on the status bar on \(name)")
            }
        }
    }

    /// Sizes track the scale factor exactly — this is what makes the iPad
    /// controls physically bigger rather than merely repositioned.
    func testControlDiametersTrackTheScaleFactor() {
        for (name, rect) in Self.allBounds {
            let l = layout(rect)
            for control in TouchOverlayControl.allCases {
                XCTAssertEqual(l.frame(for: control).width,
                               control.baseDiameter * l.scale, accuracy: 0.001,
                               "\(control.rawValue) diameter is off on \(name)")
            }
        }
    }

    func testStickRadiusTracksTheScaleFactor() {
        XCTAssertEqual(layout(Bounds.iPhone17ProLandscape).stickRadius, 60, accuracy: 0.001)
        let iPad = layout(Bounds.iPadPro13Landscape)
        XCTAssertEqual(iPad.stickRadius, 60 * iPad.scale, accuracy: 0.001)
    }

    /// The knob is drawn inside the stick base, so it has to scale by the
    /// same factor — otherwise the iPad gets a large base ring with a
    /// phone-sized dot rattling around in it.
    func testKnobRadiusTracksTheStickRadius() {
        XCTAssertEqual(layout(Bounds.iPhone17ProLandscape).knobRadius, 26, accuracy: 0.001)
        let iPad = layout(Bounds.iPadPro13Landscape)
        XCTAssertEqual(iPad.knobRadius, 26 * iPad.scale, accuracy: 0.001)
        XCTAssertLessThan(iPad.knobRadius, iPad.stickRadius)
    }

    /// The phone's tuned control *sizes* are the reference and must come
    /// back unchanged at scale 1.0. (Positions deliberately moved — see
    /// testWeaponButtonsClusterWithFire — but nothing was resized.)
    func testReferenceDeviceReproducesShippedDiameters() {
        let l = layout(Bounds.iPhone17ProLandscape)
        XCTAssertEqual(l.frame(for: .fire).width, 84, accuracy: 0.001)
        XCTAssertEqual(l.frame(for: .use).width, 64, accuracy: 0.001)
        for small in [TouchOverlayControl.weaponPrev, .weaponNext, .automap, .menu] {
            XCTAssertEqual(l.frame(for: small).width, 48, accuracy: 0.001)
        }
    }

    /// The debug HUD claims a strip at the top edge; the top-corner controls
    /// must sit below it rather than under it.
    func testTopControlsClearTheDebugHudReserve() {
        let reserve: CGFloat = 22
        let l = layout(Bounds.iPhone17ProLandscape, hudReserve: reserve)
        for control in [TouchOverlayControl.automap, .menu] {
            XCTAssertGreaterThanOrEqual(l.frame(for: control).minY, reserve - 0.001,
                                        "\(control.rawValue) overlaps the debug HUD strip")
        }
    }

    /// Safe-area insets are where the notch and home indicator live; a
    /// control placed under them is unreachable.
    func testControlsRespectSafeAreaInsets() {
        let insets = UIEdgeInsets(top: 12, left: 59, bottom: 21, right: 59)
        let rect = Bounds.iPhone17ProLandscape
        let l = layout(rect, insets: insets)
        let usable = rect.inset(by: insets)
        for control in TouchOverlayControl.allCases {
            XCTAssertTrue(usable.contains(l.frame(for: control)),
                          "\(control.rawValue) is under a safe-area inset")
        }
    }
}
