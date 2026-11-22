import SwiftUI

extension View {
    /// Makes scroll content report its container's width, whatever the
    /// content itself measures.
    ///
    /// A vertical `ScrollView` is as wide as its content when the content
    /// reports wider than it was offered, and a `Text` can do that by a
    /// fraction of a point: offered 312.5 pt, a wrapping line that fills it
    /// was measured reporting 312.667. `ShelfView` measures its scroll view
    /// to size the hero's art, so that sixth of a point went round: a wider
    /// scroll view, wider art, a different line break, a different width,
    /// and the first frame was never drawn (issue #437: a white screen at
    /// full CPU on an open iPhone Duo turned tall, at the largest text size).
    ///
    /// Held to the container, the content's width is the scroll view's own
    /// by construction, so nothing the content measures can reach the
    /// measurement. The content is still laid out in that width and may draw
    /// a hair outside it; only what it *reports* is fixed.
    ///
    /// A custom `Layout` that reported its proposal did the same job and was
    /// tried first. With it round the shelf's content, CI's unit tests failed
    /// five runs in five: see
    /// `docs/learnings/a-scroll-view-measured-to-lay-out-its-own-content-can-spin.md`.
    ///
    /// `ScrollContentWidthTests` is the check.
    func reportingContainerWidth() -> some View {
        containerRelativeFrame(.horizontal, alignment: .leading)
    }
}
