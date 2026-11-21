import SwiftUI

/// The notice an import ends with, floating over the shelf.
///
/// Its text has no line limit, on purpose: the longest notice (an adoption of
/// two add-ons with one failure) is 113 characters, and what it ends with,
/// "1 failed (moved to Import Failed)", is the part a reader most needs. So
/// it wraps, to three lines on a closed iPhone Duo at the default text size
/// and to many more at an accessibility size, and the background has to be a
/// shape that holds a block of text: `waddleBanner()`'s rounded rectangle,
/// with the text padded clear of its corners on both axes. As a capsule the
/// ends grew with the height until the first and last lines began outside
/// them (issue #423); `ImportNoticeBannerTests` is the check.
struct ImportNoticeBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typography.secondary)
            .multilineTextAlignment(.center)
            // Where the window is too short for it at the reader's text size
            // (a closed iPhone Duo at the largest accessibility size, where
            // nine lines do not fit), the text shrinks to fit rather than
            // lose its end to an ellipsis: the end is the failure count.
            .minimumScaleFactor(0.5)
            .padding(.horizontal, Theme.Spacing.base)
            .padding(.vertical, Theme.Spacing.sm)
            // Tappable to dismiss, so it is one of the controls the shell
            // draws itself and owes spec §5's 44 pt minimum; `contentShape`
            // makes the whole banner hittable rather than just the glyphs.
            .frame(minHeight: Theme.minimumTapTarget)
            .waddleBanner()
            .contentShape(Theme.bannerShape)
    }
}
