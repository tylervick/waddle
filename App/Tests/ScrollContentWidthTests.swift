import SwiftUI
import XCTest
@testable import Waddle

/// The shelf's content cannot change the width the shelf is measured at
/// (issue #437).
///
/// `ShelfView` measures its scroll view and sizes the hero's art from the
/// result. A scroll view follows content that reports wider than it was
/// offered, so content a sixth of a point over (a wrapping `Text`) changed
/// the measurement, which changed the content, and on an open iPhone Duo
/// turned tall at the largest text size the first frame never came.
/// `OfferedWidthScrollView`, which `ShelfView` is built on, holds the
/// content's reported width to the width the scroll view is offered.
///
/// This is the loop itself in miniature, not the shelf: a scroll view,
/// measured the way the shelf measures its own, around content that always
/// reports a sixth of a point wider than the last measurement. It cannot say
/// that `ShelfView` is still built on it: `ShelfContainerWidthTests`
/// hosts the real shelf for that. Nor can it say that no other path feeds
/// the measurement; the launch scan in the learning is the check of the real
/// screen, and needs a Duo opened in Device Hub.
///
/// The second half is the same question asked of `GamePageView`, which
/// measures a `Form` and a row inside it (issue #450). A form is not widened
/// by its content. A row is, and `onOfferedWidthChange` is what the page
/// measures its hero row with instead; `GamePageMeasurementTests` hosts the
/// real page.
@MainActor
final class ScrollContentWidthTests: XCTestCase {
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
            scroll
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                record.widths.append(width)
                if record.widths.count < ScrollContentWidthTests.steps { measured = width }
            }
        }

        @ViewBuilder private var scroll: some View {
            if guarded {
                OfferedWidthScrollView { content }
            } else {
                ScrollView { content }
            }
        }

        private var content: some View {
            Color.clear.frame(width: measured > 0 ? measured + ScrollContentWidthTests.excess : nil,
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

    /// The discrimination: unguarded, the content's excess reaches the
    /// measurement and the measurement walks away from the window. This is
    /// what `main` did, and if it ever stops being true the test below is no
    /// longer testing anything.
    func testUnguardedContentWidensItsOwnMeasurement() {
        let widths = widthsMeasured(guarded: false)
        XCTAssertGreaterThan(widths.count, 2, "the unguarded scroll view was measured \(widths)")
        XCTAssertGreaterThan(widths.max() ?? 0, Self.window.width + Self.excess / 2,
                             "content wider than offered no longer widens a scroll view: \(widths)")
    }

    /// Guarded, the scroll view is measured once, at the window's width.
    func testGuardedContentLeavesTheMeasurementAtTheWindowsWidth() {
        let widths = widthsMeasured(guarded: true)
        XCTAssertFalse(widths.isEmpty, "the scroll view was never measured")
        for width in widths {
            XCTAssertEqual(width, Self.window.width, accuracy: 0.0001, "measured \(widths)")
        }
        XCTAssertEqual(widths.count, 1, "the measurement changed after it was first taken: \(widths)")
    }

    // MARK: An offer that shrinks (issue #469)

    /// The open iPhone Duo held wide, and the column the shelf had beside
    /// the Settings panel there.
    private static let wide: CGFloat = 951
    private static let column: CGFloat = 491

    /// Content that fills what it is offered: a wrapping line over a block.
    private struct Filling: View {
        var body: some View {
            VStack(alignment: .leading) {
                Text("Bring your own WADs, or start with the Freedoom games below.")
                Color.clear.frame(height: 100)
            }
            .padding(16)
        }
    }

    /// The scroll view's frame in the window, after the window is laid out
    /// at `wide` and then narrowed to `column`, as the panel's column
    /// narrowed the shelf's.
    private func scrollFrameAfterShrinking<V: View>(_ view: V) -> CGRect? {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.wide, height: Self.window.width))
        window.rootViewController = UIHostingController(rootView: view.ignoresSafeArea())
        window.isHidden = false
        func settle() {
            for _ in 0..<20 {
                window.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
        settle()
        window.frame = CGRect(x: 0, y: 0, width: Self.column, height: Self.window.width)
        settle()
        let frame = scrollViews(in: window).first.map { $0.convert($0.bounds, to: window) }
        window.isHidden = true
        window.rootViewController = nil
        return frame
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        if let scroll = view as? UIScrollView { found.append(scroll) }
        for sub in view.subviews { found += scrollViews(in: sub) }
        return found
    }

    /// The discrimination: content held to its container, which is how the
    /// shelf was guarded until issue #469, keeps the scroll view at its old
    /// width when the offer shrinks, centred on the new one and cut at both
    /// sides. The container is the scroll view, and the scroll view is as
    /// wide as that content. If this ever stops being true the test below
    /// is no longer testing anything.
    func testContentHeldToItsContainerKeepsAScrollViewWideWhenItsOfferShrinks() throws {
        let frame = try XCTUnwrap(scrollFrameAfterShrinking(ScrollView {
            Filling().containerRelativeFrame(.horizontal, alignment: .leading)
        }))
        XCTAssertGreaterThan(frame.width, Self.column + 1,
                             "a scroll view held to its container now follows a shrinking offer: \(frame)")
    }

    /// Built on the offer, the scroll view is the new width, at the
    /// window's leading edge.
    func testAnOfferedWidthScrollViewFollowsAShrinkingOffer() throws {
        let frame = try XCTUnwrap(scrollFrameAfterShrinking(OfferedWidthScrollView { Filling() }))
        XCTAssertEqual(frame.minX, 0, accuracy: 0.0001, "the scroll view is at \(frame)")
        XCTAssertEqual(frame.width, Self.column, accuracy: 0.0001, "the scroll view is at \(frame)")
    }

    // MARK: A form, and a row in it (issue #450)

    private final class FormRecord {
        var form: [CGFloat] = []
        var row: [CGFloat] = []
    }

    /// A form measured as `GamePageView` measures its own, holding a row
    /// shaped like the page's hero row: zero insets, and a
    /// `frame(maxWidth: .infinity)` round content that reports `excess` more
    /// than the last width measured.
    private struct FormLoop: View {
        enum Feed {
            /// The content follows the form's width.
            case form
            /// The content follows the row's width, read off the row's frame.
            case rowFrame
            /// The content follows the row's width, read as the page reads it.
            case rowOffer
        }

        let feed: Feed
        let record: FormRecord
        @State private var measured: CGFloat = 0

        var body: some View {
            Form {
                Section {
                    row.listRowInsets(EdgeInsets())
                }
                Section { Text("The row below the hero") }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                record.form.append(width)
                if feed == .form { follow(width, count: record.form.count) }
            }
        }

        @ViewBuilder private var row: some View {
            let framed = Color.clear
                .frame(width: measured > 0 ? measured + ScrollContentWidthTests.excess : nil, height: 100)
                .frame(maxWidth: .infinity, alignment: .leading)
            if feed == .rowOffer {
                framed.onOfferedWidthChange { width in
                    record.row.append(width)
                    follow(width, count: record.row.count)
                }
            } else {
                framed.onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    record.row.append(width)
                    if feed == .rowFrame { follow(width, count: record.row.count) }
                }
            }
        }

        private func follow(_ width: CGFloat, count: Int) {
            if count < ScrollContentWidthTests.steps { measured = width }
        }
    }

    private func formWidthsMeasured(feed: FormLoop.Feed) -> FormRecord {
        let record = FormRecord()
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.window))
        window.rootViewController = UIHostingController(rootView: FormLoop(feed: feed, record: record)
            .ignoresSafeArea())
        window.isHidden = false
        for _ in 0..<(Self.steps * 2) {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        window.isHidden = true
        window.rootViewController = nil
        return record
    }

    /// A form is not a scroll view in this: a row that reports wider than
    /// the form does not widen the form, so `GamePageView`'s measurement of
    /// its form cannot feed itself. The row did report over, or this would
    /// be showing nothing.
    func testAFormIsNotWidenedByARowThatReportsWiderThanIt() {
        let record = formWidthsMeasured(feed: .form)
        XCTAssertEqual(record.form.count, 1, "the form's measurement changed after it was first taken: \(record.form)")
        for width in record.form {
            XCTAssertEqual(width, Self.window.width, accuracy: 0.0001, "measured \(record.form)")
        }
        XCTAssertGreaterThan(record.row.max() ?? 0, Self.window.width + Self.excess / 2,
                             "the row never reported wider than the form: \(record.row)")
    }

    /// The discrimination for the row: read off its own frame, a row is as
    /// wide as content that reports over, and the measurement walks away.
    /// This is what `GamePageView`'s hero row did, and if it ever stops
    /// being true the test below is no longer testing anything.
    func testARowMeasuredOffItsFrameIsWidenedByItsContent() {
        let widths = formWidthsMeasured(feed: .rowFrame).row
        XCTAssertGreaterThan(widths.count, 2, "the row was measured \(widths)")
        XCTAssertGreaterThan((widths.max() ?? 0) - (widths.first ?? 0), Self.excess * 2,
                             "content wider than offered no longer widens a row's frame: \(widths)")
    }

    /// Read as the offer, the row's width is taken once, whatever its
    /// content reports.
    func testARowsOfferedWidthIsNotChangedByItsContent() {
        let record = formWidthsMeasured(feed: .rowOffer)
        XCTAssertEqual(record.row.count, 1, "the row's measurement changed after it was first taken: \(record.row)")
        XCTAssertEqual(record.form.count, 1, "the form's measurement changed: \(record.form)")
        if let row = record.row.first, let form = record.form.first {
            XCTAssertGreaterThan(row, 0)
            XCTAssertLessThanOrEqual(row, form, "a row was offered more than its form: \(row) in \(form)")
        }
    }
}
