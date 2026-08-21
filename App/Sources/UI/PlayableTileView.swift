import SwiftUI

/// Renders a single playable tile (spec §5): TITLEPIC art on a 4:3 shape, the
/// title on a bottom scrim, one shared corner radius. Wrapped by callers in a
/// `Button` for the tap action and the accessibility identifier/context menu,
/// since those differ per caller — the VoiceOver label goes on that same
/// button, so it replaces the whole tile's contents rather than reading them
/// out piecemeal.
///
/// `subtitle` is optional and unset on the shelf: the shelf mixes base games
/// and presets in one grid with no kind labels (spec §2), so identity comes
/// from the art and the recognized title alone.
struct PlayableTileView: View {
    let item: PlayableItem
    var subtitle: String?
    let library: LibraryService

    var body: some View {
        TitleArtView(item: item, library: library)
            .overlay(alignment: .bottom) { scrim }
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
    /// `lineLimit(1)`, where this used to allow two: on a 4:3 tile a second line
    /// puts the scrim straight back over that ceiling. The cost is accepted
    /// knowingly — long preset names such as "Freedoom Phase 2 + SCYTHE"
    /// truncate. VoiceOver is unaffected: the accessibility label sits on the
    /// wrapping `Button` and replaces the tile's contents, so the spoken title
    /// is still the whole one.
    private var scrim: some View {
        VStack(alignment: .leading, spacing: PlayableTileLayout.titleSubtitleSpacing) {
            Text(item.title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.appSecondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PlayableTileLayout.scrimHorizontalPadding)
        .padding(.top, PlayableTileLayout.scrimTopPadding)
        .padding(.bottom, PlayableTileLayout.scrimBottomPadding)
        .background(
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}
