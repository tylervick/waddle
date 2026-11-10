import UIKit
import XCTest
@testable import Waddle

/// The overlay geometry, measured against the device the suite is *running
/// on* rather than a table of literal bounds.
///
/// ## Why this file exists at all
///
/// `TouchOverlayLayoutTests` is the pure-geometry suite: it hands
/// `TouchOverlayLayout` a rect and asserts what comes back. Every one of its
/// assertions produces the same verdict on every destination, because no part
/// of it can observe which device it is on. That is the gap issue #131 names —
/// the app ships universal, iPad is the device it is built for, and until this
/// file every automated check of iPad geometry was a phone reading numbers it
/// had been handed.
///
/// These tests read the live screen, the live window, and the safe-area
/// insets the system actually reports, so they are the only ones in the suite
/// whose verdict depends on the destination. That is deliberate and
/// load-bearing: the iPad leg added to `ci.yml` and `mise run test` buys
/// nothing unless something can fail on iPad while the iPhone leg stays green,
/// and this is that something. Adding a third destination means adding a row
/// to `pinnedDestinations` below — not just a new `xcodebuild` invocation.
///
/// Both legs run this file. Nothing here is `XCTSkip`ped by idiom: a skip on
/// the destination that matters is indistinguishable from coverage.
@MainActor
final class LiveDeviceOverlayLayoutTests: XCTestCase {

    /// A destination this repo pins and runs the suite against, and what the
    /// overlay must resolve to there.
    ///
    /// `shortSide` is the screen's smaller dimension in points, which is the
    /// one screen measurement that does not move when the device rotates.
    /// Sizes are the CoreSimulator device profiles; the expected scales follow
    /// from `TouchOverlayLayout`'s own formula, `min(short / 402, long / 874)`
    /// clamped to [0.5, 1.75]:
    ///
    /// - iPhone 17 Pro, 402x874 -> min(1.0, 1.0) = 1.0
    /// - iPad Pro 13-inch (M4), 1032x1376 -> min(2.567, 1.574) = 1.574
    /// - iPhone Duo, closed, 466x678 -> min(1.159, 0.776) = 0.776
    /// - iPhone Duo, open, 669x951 -> min(1.664, 1.088) = 1.088
    ///
    /// The Duo has two rows because it has two displays, and which one the
    /// scene is on depends on whether the device is folded. A simulator boots
    /// closed, which is the pose CI gets (nothing Apple ships opens it from a
    /// command line; `docs/learnings/iphone-duo-simulator-traps.md`), but
    /// both are pinned so a leg that somehow ran open would still be held to
    /// an exact figure rather than falling through to the unpinned bands.
    private struct PinnedDestination {
        let name: String
        let shortSide: CGFloat
        let idiom: UIUserInterfaceIdiom
        let scale: CGFloat
    }

    private static let pinnedDestinations: [PinnedDestination] = [
        PinnedDestination(name: "iPhone 17 Pro", shortSide: 402, idiom: .phone, scale: 1.0),
        PinnedDestination(name: "iPad Pro 13-inch (M4)", shortSide: 1032, idiom: .pad, scale: 1.574),
        PinnedDestination(name: "iPhone Duo (closed)", shortSide: 466, idiom: .phone, scale: 0.776),
        PinnedDestination(name: "iPhone Duo (open)", shortSide: 669, idiom: .phone, scale: 1.088),
    ]

    /// Whether the suite is running on an iPhone Duo simulator, from the name
    /// CoreSimulator gives the process. The Duo leg exists to assert Duo
    /// figures, so on that device an unpinned screen is a failure, not a
    /// fallback: a leg that quietly took the generic phone band would report
    /// coverage it did not provide.
    private static var isIPhoneDuo: Bool {
        (ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "").contains("Duo")
    }

    /// Bands for a destination this repo does not pin — a developer running
    /// the suite on some other simulator. They are deliberately disjoint,
    /// because the invariant worth asserting there is the reason the scale
    /// factor exists: no phone and no iPad may resolve to the same overlay
    /// size. The extremes bound it comfortably — the largest phone that runs
    /// iOS 26 is the 17 Pro Max (440x956 pt -> 1.094) and the smallest iPad is
    /// the mini (744x1133 pt -> 1.296).
    private static let phoneScaleCeiling: CGFloat = 1.15
    private static let padScaleFloor: CGFloat = 1.25

    private struct NoLiveWindow: Error, CustomStringConvertible {
        var description: String
    }

    /// The window the host app is actually showing.
    ///
    /// Polled rather than read once: `WaddleApp` is a SwiftUI `WindowGroup`
    /// and scene connection is asynchronous, so a bare read can land before
    /// the scene exists. Failing on that race would read as an iPad geometry
    /// regression when it is a startup timing artefact — and this file is the
    /// one whose red is supposed to mean something specific.
    private func liveWindow() throws -> UIWindow {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            if let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first,
               window.windowScene != nil,
               !window.bounds.isEmpty {
                return window
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        throw NoLiveWindow(description:
            "the host app never presented a window, so no live geometry could be read")
    }

    /// The scale the overlay resolves to on this destination's screen.
    ///
    /// Screen, not window: under iPadOS 26's "Windowed Apps" multitasking the
    /// host's window can be smaller than the display, and this assertion is
    /// about the device the leg is pinned to. Insets are zero here for the
    /// same reason — the safe area moves with orientation and window, and
    /// `testLiveWindowKeepsEveryControlReachable` is the one that consumes the
    /// real values.
    func testLiveScreenResolvesToThePinnedOverlayScale() throws {
        let window = try liveWindow()
        let screen = try XCTUnwrap(window.windowScene, "live window has no scene").screen
        let bounds = screen.bounds
        let shortSide = min(bounds.width, bounds.height)
        let layout = TouchOverlayLayout(bounds: bounds, safeAreaInsets: .zero, hudReserve: 0)
        let idiom = UIDevice.current.userInterfaceIdiom

        guard let pinned = Self.pinnedDestinations
            .first(where: { abs($0.shortSide - shortSide) < 0.5 }) else {
            // Not a destination this repo pins. Still assert the thing that
            // must be true of every device rather than skipping, which would
            // let an unfamiliar simulator report coverage it did not provide.
            XCTAssertFalse(Self.isIPhoneDuo,
                           "an iPhone Duo presented a screen of \(bounds.size), which is neither "
                           + "of its two displays (466x678 closed, 669x951 open)")
            switch idiom {
            case .pad:
                XCTAssertGreaterThanOrEqual(
                    layout.scale, Self.padScaleFloor,
                    "an iPad (screen \(bounds.size)) resolved to \(layout.scale), "
                    + "which is in phone territory — the overlay would be phone-sized here")
            case .phone:
                XCTAssertLessThanOrEqual(
                    layout.scale, Self.phoneScaleCeiling,
                    "a phone (screen \(bounds.size)) resolved to \(layout.scale), "
                    + "which is in iPad territory")
            default:
                XCTFail("unsupported idiom \(idiom.rawValue) with screen \(bounds.size)")
            }
            return
        }

        XCTAssertEqual(idiom, pinned.idiom,
                       "screen short side \(shortSide) says \(pinned.name), but the reported "
                       + "idiom is \(idiom.rawValue) — the app is probably running scaled "
                       + "rather than natively")
        XCTAssertEqual(layout.scale, pinned.scale, accuracy: 0.001,
                       "\(pinned.name) must scale the overlay by \(pinned.scale); got \(layout.scale)")
    }

    /// Every control reachable in the window the app is *actually* in, with
    /// the safe-area insets the system actually reports.
    ///
    /// This is the half a pure-geometry test cannot do. `TouchOverlayLayoutTests`
    /// proves these invariants hold for insets someone typed into a fixture;
    /// this proves they hold for the ones iPadOS hands the app at runtime, in
    /// whatever window the multitasking style put it in.
    func testLiveWindowKeepsEveryControlReachable() throws {
        let window = try liveWindow()
        let bounds = window.bounds
        let insets = window.safeAreaInsets
        let layout = TouchOverlayLayout(bounds: bounds, safeAreaInsets: insets, hudReserve: 0)
        let usable = bounds.inset(by: insets)
        let context = "window \(bounds), insets \(insets), scale \(layout.scale)"

        XCTAssertFalse(usable.isEmpty, "the safe area consumed the whole window — \(context)")

        for control in TouchOverlayControl.allCases {
            XCTAssertTrue(usable.contains(layout.frame(for: control)),
                          "\(control.rawValue) at \(layout.frame(for: control)) is outside the "
                          + "safe area \(usable) — \(context)")
        }

        let controls = TouchOverlayControl.allCases
        for (index, a) in controls.enumerated() {
            for b in controls[(index + 1)...] {
                XCTAssertFalse(layout.frame(for: a).intersects(layout.frame(for: b)),
                               "\(a.rawValue) overlaps \(b.rawValue) — \(context)")
            }
        }

        // The regression this issue was filed over, checked against live
        // geometry: FIRE and USE sat on top of Doom's status bar in
        // docs/app-store/screenshots/ipad-13/05-ingame.png.
        let floor = usable.maxY - layout.statusBarReserve
        for control in [TouchOverlayControl.fire, .use, .weaponPrev, .weaponNext] {
            XCTAssertLessThanOrEqual(layout.frame(for: control).maxY, floor + 0.001,
                                     "\(control.rawValue) intrudes on the status bar reserve "
                                     + "(\(layout.statusBarReserve)pt) — \(context)")
        }
    }

    /// Issue #351, against live geometry: the bottom cluster clear of Doom's
    /// status bar where the engine will draw it, not where the window ends.
    ///
    /// `TouchOverlayLayoutStatusBarTests` proves this for rects and zero
    /// insets someone typed. Here the window and its safe-area insets are the
    /// ones the system reports, which on a closed iPhone Duo include the
    /// status column down one side, and the picture is the one a session
    /// starts with (`predictedPictureRect`). This is the case that fails on
    /// the Duo leg alone if the layout goes back to assuming the bar is at
    /// the bottom of the window; on a phone in portrait the cluster is far
    /// below the picture either way.
    func testLiveWindowKeepsTheBottomClusterOffTheStatusBar() throws {
        let window = try liveWindow()
        let bounds = window.bounds
        let insets = window.safeAreaInsets
        let picture = TouchOverlayLayout.predictedPictureRect(in: bounds)
        let layout = TouchOverlayLayout(bounds: bounds, safeAreaInsets: insets, hudReserve: 0,
                                        pictureRect: picture)
        let barHeight = picture.height * 32 / 200
        let bar = CGRect(x: picture.minX, y: picture.maxY - barHeight,
                         width: picture.width, height: barHeight)
        let context = "window \(bounds), insets \(insets), picture \(picture), scale \(layout.scale)"

        for control in [TouchOverlayControl.fire, .use, .weaponPrev, .weaponNext] {
            let frame = layout.frame(for: control)
            XCTAssertFalse(TouchOverlayLayout.overlaps(frame, bar),
                           "\(control.rawValue) at \(frame) is on the status bar \(bar) — \(context)")
            XCTAssertTrue(bounds.inset(by: insets).contains(frame),
                          "\(control.rawValue) at \(frame) left the safe area — \(context)")
        }
    }

    /// The premise the other two rest on: the host app is genuinely built for
    /// both idioms.
    ///
    /// If `TARGETED_DEVICE_FAMILY` ever lost its `2`, the app would run on an
    /// iPad in iPhone compatibility mode — reporting a phone idiom and a
    /// phone-sized screen. The iPad leg would then match the *iPhone* row
    /// above and pass, quietly testing a phone twice. This is what stops that
    /// from being silent.
    ///
    /// `Bundle.main` inside a hosted unit-test bundle is the host app, not the
    /// test bundle, so this reads the shipped Info.plist.
    func testHostAppIsBuiltForIPadAndIPhone() throws {
        let families = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "UIDeviceFamily") as? [Int],
            "the host app declares no UIDeviceFamily at all")
        XCTAssertTrue(families.contains(1), "iPhone dropped from UIDeviceFamily: \(families)")
        XCTAssertTrue(families.contains(2),
                      "iPad dropped from UIDeviceFamily: \(families) — the app would run scaled "
                      + "on iPad and the iPad test leg would be testing a phone")
    }
}
