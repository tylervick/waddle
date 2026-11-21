import SwiftUI

/// Reports exactly the width it was proposed, whatever its content says.
///
/// A vertical `ScrollView` is as wide as its content when the content
/// reports wider than it was offered, and a `Text` can do that by a fraction
/// of a point: offered 312.5 pt, a wrapping line that fills it was measured
/// reporting 312.667. `ShelfView` measures its scroll view to
/// size the hero's art, so that sixth of a point went round: a wider scroll
/// view, wider art, a different line break, a different width, and the first
/// frame was never drawn (issue #437: a white screen at full CPU on an open
/// iPhone Duo turned tall, at the largest text sizes).
///
/// Wrapped in this, the content's width is the scroll view's own proposal by
/// construction, so nothing the content measures can reach the measurement.
/// The content is still laid out in that width and may draw a hair outside
/// it; only what it *reports* is fixed. Height is the content's own.
///
/// `ProposedWidthLayoutTests` is the check.
struct ProposedWidthLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var size = CGSize.zero
        for subview in subviews {
            let fitted = subview.sizeThatFits(proposal)
            size.width = max(size.width, fitted.width)
            size.height = max(size.height, fitted.height)
        }
        // No width offered (an ideal-size query) or an unbounded one: there
        // is nothing to hold the content to, so its own answer stands.
        if let width = proposal.width, width.isFinite { size.width = width }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: proposal.height))
        }
    }
}
