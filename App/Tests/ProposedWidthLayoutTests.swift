import SwiftUI
import XCTest
@testable import Waddle

/// The shelf's content cannot change the width the shelf is measured at
/// (issue #437).
///
/// `ShelfView` measures its scroll view and sizes the hero's art from the
/// result. A scroll view follows content that reports wider than it was
/// offered, so content a sixth of a point over (a `Text` rounding up to a
/// pixel) changed the measurement, which changed the content, and on an open
/// iPhone Duo turned tall at the largest text sizes the first frame never
/// came. `ProposedWidthLayout` holds the content's reported width to the
/// offer.
///
/// This is the loop itself in miniature, not the shelf: a scroll view,
/// measured the way the shelf measures its own, around content that always
/// reports a sixth of a point wider than the last measurement. It cannot say
/// that `ShelfView` uses the layout, or that no other path feeds the
/// measurement; the launch scan in the learning is the check of the real
/// screen, and needs a Duo opened in Device Hub.
@MainActor
final class ProposedWidthLayoutTests: XCTestCase {
    /// The open iPhone Duo turned tall, where the hang was.
    private static let window = CGSize(width: 669, height: 951)
    /// Half a pixel at 3x: what the shelf's content was over by.
    private static let excess: CGFloat = 1.0 / 6.0
    /// The stand-in stops growing here, so that the unguarded loop ends and
    /// can be counted instead of hanging the suite as it hung the app.
    private static let steps = 40

    private final class Record {
        var widths: [CGFloat] = []
    }

    /// A scroll view measured as `ShelfView` measures its own, whose content
    /// reports `excess` more than the last width measured.
    private struct Loop: View {
        let guarded: Bool
        let record: Record
        @State private var measured: CGFloat = 0

        var body: some View {
            ScrollView {
                if guarded {
                    ProposedWidthLayout { content }
                } else {
                    content
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                record.widths.append(width)
                if record.widths.count < ProposedWidthLayoutTests.steps { measured = width }
            }
        }

        private var content: some View {
            Color.clear.frame(width: measured > 0 ? measured + ProposedWidthLayoutTests.excess : nil,
                              height: 100)
        }
    }

    private func widthsMeasured(guarded: Bool) -> [CGFloat] {
        let record = Record()
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.window))
        window.rootViewController = UIHostingController(rootView: Loop(guarded: guarded, record: record)
            .ignoresSafeArea())
        window.isHidden = false
        // Several turns: each measurement arrives a layout pass after the
        // state it follows from.
        for _ in 0..<(Self.steps * 2) {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        window.isHidden = true
        return record.widths
    }

    /// The discrimination: without the layout, the content's excess reaches
    /// the measurement and the measurement walks away from the window. This
    /// is what `main` did, and if it ever stops being true the test below is
    /// no longer testing anything.
    func testWithoutTheLayoutTheContentWidensItsOwnMeasurement() {
        let widths = widthsMeasured(guarded: false)
        XCTAssertGreaterThan(widths.count, 2, "the unguarded scroll view was measured \(widths)")
        XCTAssertGreaterThan(widths.max() ?? 0, Self.window.width + Self.excess / 2,
                             "content wider than offered no longer widens a scroll view: \(widths)")
    }

    /// With it, the scroll view is measured once, at the window's width.
    func testWithTheLayoutTheMeasurementIsTheWindowsWhateverTheContentReports() {
        let widths = widthsMeasured(guarded: true)
        XCTAssertFalse(widths.isEmpty, "the scroll view was never measured")
        for width in widths {
            XCTAssertEqual(width, Self.window.width, accuracy: 0.0001, "measured \(widths)")
        }
        XCTAssertEqual(widths.count, 1, "the measurement changed after it was first taken: \(widths)")
    }

    /// The layout reports the offer on the horizontal axis and the content's
    /// own height, and leaves an ideal-size query alone.
    func testItReportsTheOfferedWidthAndTheContentsHeight() {
        let wide = ProposedWidthLayout { Color.clear.frame(width: 500.4, height: 80) }
        let offered = UIHostingController(rootView: wide)
            .sizeThatFits(in: CGSize(width: 300, height: 1000))
        XCTAssertEqual(offered.width, 300, accuracy: 0.5)
        XCTAssertEqual(offered.height, 80, accuracy: 0.5)

        let renderer = ImageRenderer(content: wide)
        renderer.proposedSize = ProposedViewSize(width: nil, height: nil)
        XCTAssertEqual(renderer.uiImage?.size.width ?? 0, 500.4, accuracy: 1)
    }
}
