import SwiftUI

/// Renders a single playable tile: title art (`TitleArtView`), title,
/// subtitle. Used for both base-game and preset tiles in `PlayView`'s grid
/// sections. Wrapped by callers in a `Button` for the tap action and the
/// accessibility identifier/context menu, since those differ per section.
struct PlayableTileView: View {
    let item: PlayableItem
    let subtitle: String
    let library: LibraryService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TitleArtView(item: item, library: library)

            Text(item.title).font(.headline).lineLimit(2)
            Text(subtitle)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
