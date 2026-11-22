import SwiftUI
import UIKit

/// Renders a single playable tile (spec §5): TITLEPIC art on a 4:3 shape, the
/// title on a bottom scrim, one shared corner radius. Wrapped by callers in a
/// `Button` for the tap action and the accessibility identifier/context menu,
/// since those differ per caller — the VoiceOver label goes on that same
/// button, so it replaces the whole tile's contents rather than reading them
/// out piecemeal.
///
/// `subtitle` is optional and unset on the shelf: the shelf mixes base games
/// and modded games in one grid with no kind labels (spec §2), so identity
/// comes from the art and the recognized title alone.
struct PlayableTileView: View {
    let game: Game
    var subtitle: String?
    let library: LibraryService
    /// The tile's shape. 4:3 everywhere but the shelf in a window too short
    /// for a one-column tile, where the shelf passes a wider one
    /// (`PlayableTileLayout.tileAspectRatio(width:viewportHeight:contentPadding:)`).
    var aspectRatio: CGFloat = Theme.tileAspectRatio
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        TitleArtView(game: game, library: library, aspectRatio: aspectRatio)
            .overlay(alignment: .bottom) { scrim }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            // The hairline that makes the tile an object (spec §5, amended
            // 2026-08-21): edge-to-edge art against the near-black page has
            // no boundary of its own, so without a stroke two adjacent tiles
            // read as one continuous poster whatever the gap between them.
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Color.appHairline, lineWidth: Theme.tileHairlineWidth)
            )
            .overlay(alignment: .topTrailing) {
                // A warning, not a call to action: the badge used to wear the
                // accent, which spec §5 reserves for primary actions, so an
                // unpaired game looked like it was inviting a tap.
                if game.baseID == nil {
                    StatusBadge("Needs a base game", tone: .warning)
                        .padding(Theme.Spacing.sm)
                        .accessibilityIdentifier("unpairedBadge")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    /// The title's bed: a bottom-anchored gradient dark enough to keep white
    /// type legible over whatever the art happens to be there. It sits over the
    /// flat fallback tile too, so both states put the title in the same place.
    ///
    /// Every metric comes from `PlayableTileLayout` rather than being a literal
    /// here, because the scrim now has a ceiling to stay under — at most 40% of
    /// the tile at one line — and a budget checked against numbers the view does
    /// not actually draw with would not be checking anything.
    ///
    /// `lineLimit(1)` up to the default text size, where this used to allow
    /// two: on a 4:3 tile a second line puts the scrim straight back over that
    /// ceiling. The cost is accepted knowingly — long preset names such as
    /// "Freedoom Phase 2 + SCYTHE" truncate. VoiceOver is unaffected: the
    /// accessibility label sits on the wrapping `Button` and replaces the
    /// tile's contents, so the spoken title is still the whole one.
    ///
    /// Above the default size the title has two lines
    /// (`PlayableTileLayout.titleLineLimit`): the ceiling is a budget for the
    /// default size, and a reader who asked for larger type is owed the name
    /// before the art.
    private var scrim: some View {
        VStack(alignment: .leading, spacing: PlayableTileLayout.titleSubtitleSpacing) {
            title
                .foregroundStyle(.white)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Color.appSecondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PlayableTileLayout.scrimHorizontalPadding)
        .padding(.top, PlayableTileLayout.scrimTopPadding)
        .padding(.bottom, PlayableTileLayout.scrimBottomPadding)
        .background(
            // Weighted stops, not a linear two-stop ramp: with 0 → 0.85 the
            // title's baseline sat in the ramp's thin half and the type read
            // as printed straight on the art, colliding with the wordmark
            // TITLEPIC itself carries (2026-08-21 design pass). Pulling the
            // bed to near-full density by the title's top keeps the fade but
            // gives the text an actual ground. Same height, same ceiling —
            // `PlayableTileLayout`'s numbers are untouched.
            LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                   .init(color: .black.opacity(0.75), location: 0.55),
                                   .init(color: .black.opacity(0.92), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    @ViewBuilder
    private var title: some View {
        let lines = PlayableTileLayout.titleLineLimit(
            largerThanDefaultText: dynamicTypeSize > .large)
        if lines == 1 {
            oneLineTitle
        } else {
            // Larger type than the default (issue #426). The one-line shrink
            // reaches 0.85 and no further; from one Dynamic Type step up
            // "Freedoom Phase 1" and "Freedoom Phase 2" need less than that
            // in a two-column tile and were both cut before the digit.
            //
            // So: the one line, shrunk as before, wherever that holds the
            // whole name, and otherwise the name at its own size on a second
            // line. `ViewThatFits` takes the first whose ideal width fits,
            // and the one line declares the least it can be drawn in.
            ViewThatFits(in: .horizontal) {
                oneLineTitle
                    .frame(idealWidth: PlayableTileLayout.oneLineTitleMinimumWidth(
                        fullWidth: titleWidth))
                // `WholeWordText` and not a `Text` with a scale factor: a
                // wrapped `Text` breaks a word wider than its line rather
                // than shrink
                // (`docs/learnings/words-broken-mid-word-at-accessibility-sizes.md`).
                // Its smaller sizes are plain system fonts, so the weight is
                // put back here. A name longer than the lines still truncates.
                WholeWordText(game.name, textStyle: Theme.Typography.tileTitleStyle)
                    .font(Theme.Typography.tileTitle)
                    .fontWeight(.semibold)
                    .lineLimit(lines)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var oneLineTitle: some View {
        Text(game.name)
            .font(Theme.Typography.tileTitle)
            .lineLimit(1)
            // Shrink a little before truncating: two games whose names
            // differ only in their last character must not read the same
            // (issue #353). Still one line, so the scrim's height and its
            // ceiling are untouched.
            .minimumScaleFactor(PlayableTileLayout.titleMinimumScaleFactor)
    }

    /// The name on one line at the reader's text size, as `UIFont` measures
    /// it. Reads the size from the environment so a change of it measures
    /// again.
    private var titleWidth: CGFloat {
        _ = dynamicTypeSize
        let font = UIFont.preferredFont(forTextStyle: Theme.Typography.tileTitleStyle)
        return (game.name as NSString).size(withAttributes: [.font: font]).width
    }
}
