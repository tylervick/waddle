import UIKit
import XCTest
@testable import Waddle

/// The in-game debug strip is read off screenshots by Revyl device runs, and
/// its tail (`… ab= mv= menu=`) is the part they need. The strip used to sit
/// in a fixed 60 pt frame, four lines of its 11 pt font; when the `gs=`
/// segment joined the second line (issue #111), a phone in portrait wrapped
/// the text to five lines and the frame clipped `menu=` away. Measured on an
/// iPhone 17 Pro Max: three lines visible, `pads=… vly=0` the last thing on
/// screen. The height must follow the text.
@MainActor
final class DebugHUDStripHeightTests: XCTestCase {
    /// A strip as the overlay composes it on a phone, second line included.
    private let phoneStrip = """
        build facedad (HEAD) · classic · events 0 · trigger 0.00 · turn 1.00 · dz 0.00 · move 1.00
        gs=level load=-1 lt=1602 · pad=Waddle Touch Controls virtual pads=2[Gamepad;Waddle Touch Controls] btn=0 ly=0 lypk=0 vly=0 ab=0 mv=0 menu=off
        """
    /// iPhone 17 Pro Max portrait, safe-area insets already removed.
    private let phoneWidth: CGFloat = 440

    func testShortTextKeepsTheFourLineMinimum() {
        XCTAssertEqual(TouchOverlayView.debugHUDStripHeight(for: "build abc (main)", width: phoneWidth),
                       TouchOverlayView.debugHUDMinimumStripHeight)
    }

    func testAPhoneWidthStripGrowsToFitEveryLine() {
        let height = TouchOverlayView.debugHUDStripHeight(for: phoneStrip, width: phoneWidth)
        XCTAssertGreaterThan(height, TouchOverlayView.debugHUDMinimumStripHeight,
                             "five wrapped lines cannot fit the four-line minimum")

        // What the same text needs when nothing limits it: the height the
        // strip claims must be at least that, or a line is clipped.
        let label = UILabel()
        label.font = TouchOverlayView.debugHUDFont
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.text = phoneStrip
        let needed = label.sizeThatFits(CGSize(width: phoneWidth, height: .greatestFiniteMagnitude)).height
        XCTAssertGreaterThanOrEqual(height, needed)
    }

    func testAWideStripStaysAtTheMinimum() {
        // Landscape on a phone, or an iPad: two lines fit, so the frame does
        // not grow past what the layout has always reserved.
        XCTAssertEqual(TouchOverlayView.debugHUDStripHeight(for: phoneStrip, width: 1200),
                       TouchOverlayView.debugHUDMinimumStripHeight)
    }
}
