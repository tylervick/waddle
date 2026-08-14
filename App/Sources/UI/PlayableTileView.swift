import SwiftUI

/// Renders a single playable tile: title art (`TitleArtView`) and title.
/// Wrapped by callers in a `Button` for the tap action and the accessibility
/// identifier/context menu, since those differ per caller.
///
/// `subtitle` is optional and unset on the shelf: the shelf mixes base games
/// and presets in one grid with no kind labels (spec §2), so identity comes
/// from the art and the recognized title alone.
struct PlayableTileView: View {
    let item: PlayableItem
    var subtitle: String?
    let library: LibraryService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TitleArtView(item: item, library: library)

            Text(item.title).font(.headline).lineLimit(2)
            if let subtitle {
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
