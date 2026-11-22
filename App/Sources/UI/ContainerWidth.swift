import SwiftUI

/// A vertical scroll view whose content is laid out at, and reports, the
/// width the scroll view is *offered*, whatever the content itself measures.
///
/// A vertical `ScrollView` is as wide as its content when the content
/// reports wider than it was offered, and a `Text` can do that by a fraction
/// of a point: offered 312.5 pt, a wrapping line that fills it was measured
/// reporting 312.667. `ShelfView` measures its scroll view to size the
/// hero's art, so that sixth of a point went round: a wider scroll view,
/// wider art, a different line break, a different width, and the first
/// frame was never drawn (issue #437: a white screen at full CPU on an open
/// iPhone Duo turned tall, at the largest text size).
///
/// The width comes from a `GeometryReader` round the scroll view, which is
/// as wide as it is offered and nothing inside it can change. The content is
/// still laid out in that width and may draw a hair outside it; only what it
/// *reports* is fixed.
///
/// `containerRelativeFrame(.horizontal)` on the content did this job before
/// and was not enough (issue #469). Its container is the scroll view, and
/// the scroll view is as wide as that content: once wide, the pair held each
/// other wide when the offer shrank. When the Settings or game panel's column
/// opened beside the shelf on an open iPhone Duo held wide, the scroll view
/// stayed 951, 763, 669 or 587 pt wide in a 491 pt column, depending on the
/// order of the layout passes the column's arrival made, and was centred in
/// it: cut at the left on every launch, differently from launch to launch.
///
/// A custom `Layout` that reported its proposal round the content was tried
/// for #437 first. With it round the shelf's content, CI's unit tests failed
/// five runs in five: see
/// `docs/learnings/a-scroll-view-measured-to-lay-out-its-own-content-can-spin.md`.
///
/// `ScrollContentWidthTests` is the check of this view, and
/// `ShelfContainerWidthTests` of its place on the real shelf.
struct OfferedWidthScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                content.frame(width: viewport.size.width, alignment: .leading)
            }
        }
    }
}

extension View {
    /// Reports the width this view is *offered*, which nothing inside it can
    /// change, instead of the width it ends up with.
    ///
    /// `onGeometryChange` on a view reads the view's own size, and a view
    /// with `frame(maxWidth: .infinity)` is as wide as its content when the
    /// content reports wider than the offer. So a row that measures itself
    /// that way to arrange its own content is measuring that content:
    /// `GamePageView`'s hero row was read a quarter of a point wide when it
    /// was stacked and exactly as offered when it was side by side, and
    /// where the rule choosing between the two fell inside that quarter
    /// point the row changed arrangement on every layout pass (issue #450).
    ///
    /// The view is put in a layout that is as wide as it is offered and as
    /// tall as the view, and that is what is measured. The view is offered
    /// what it was before and may draw a hair outside; only the width
    /// reported upward, and read here, is fixed.
    ///
    /// A clear zero-height sibling in a `VStack` was tried first, on the
    /// reasoning that a stack hands each child its own offer. It does not: a
    /// stack that a child has widened offers the others the wider width, and
    /// the sibling walked with the content, 629.0 to 635.5 in forty steps.
    ///
    /// This is a custom `Layout`, which round the shelf's whole content
    /// slowed CI's picture tests for a reason never found
    /// (`docs/learnings/a-scroll-view-measured-to-lay-out-its-own-content-can-spin.md`).
    /// It is round one row of a page that is not on screen while those run,
    /// and no built-in modifier reports an offer: `containerRelativeFrame`
    /// answers with the list's width, not the row's.
    ///
    /// `ScrollContentWidthTests` is the check of the modifier, and
    /// `GamePageMeasurementTests` of the real page.
    func onOfferedWidthChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        OfferedWidthLayout { self }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                action(width)
            }
    }
}

/// As wide as it is offered and as tall as its one subview, whatever width
/// that subview reports. An offer with no width (an ideal-size probe) is
/// answered with the subview's own.
private struct OfferedWidthLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(proposal)
        guard let width = proposal.width, width.isFinite else { return size }
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
