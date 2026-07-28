import SwiftUI

/// Renders a single playable tile: placeholder art, title, subtitle. Used for
/// both base-game and preset tiles in `PlayView`'s grid sections. Wrapped by
/// callers in a `Button` for the tap action and the accessibility
/// identifier/context menu, since those differ per section.
struct PlayableTileView: View {
    let item: PlayableItem
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Placeholder art -- Plan C replaces this fill with the loadout's
            // TITLEPIC art once WAD lump extraction lands.
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .aspectRatio(1.6, contentMode: .fit)
                .overlay(
                    Image(systemName: "flame.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                )

            Text(item.title).font(.headline).lineLimit(2)
            Text(subtitle)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
