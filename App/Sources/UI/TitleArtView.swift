import SwiftUI

/// Async-loads a `PlayableItem`'s TITLEPIC art (via `WADArtwork`) and fills the
/// requested shape with it, falling back to spec §5's flat dark tile when
/// nothing decodes.
///
/// The fallback is deliberately flat and empty: the `GeneratedArtView` monogram
/// this replaced painted a family-tinted card that reads, at a glance, as the
/// game's own artwork — "no fake art" is §5's wording. The title is not drawn
/// here either; `PlayableTileView`'s scrim carries it over art and fallback
/// alike, so the two states differ only in whether there is art behind the same
/// title.
///
/// Whether art is drawn at all goes through `TileAppearance.resolve`, which is
/// where that rule is tested — the view has no second opinion about it.
struct TitleArtView: View {
    let item: PlayableItem
    let library: LibraryService
    /// Width-to-height ratio of the shape the art fills: 3:4 on tiles, the
    /// art's own ~1.6:1 on the full-width hero (`Theme`).
    var aspectRatio: CGFloat = Theme.tileAspectRatio

    @State private var image: CGImage?

    /// The image to draw, or nil to leave the flat tile bare. Reading it
    /// through `TileAppearance` rather than testing `image` directly is what
    /// keeps the drawn result and the tested rule from drifting apart.
    private var artImage: CGImage? {
        guard case .art = TileAppearance.resolve(decodedArt: image) else { return nil }
        return image
    }

    var body: some View {
        ZStack {
            // The flat elevated tile is the floor, drawn unconditionally: it is
            // where a failed decode settles, so a tile that is still decoding
            // already shows the shape it may keep.
            Color.appSurface
            if let artImage {
                Image(decorative: artImage, scale: 1)
                    .resizable()
                    .scaledToFill()
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        // TITLEPIC is landscape and tiles are portrait, so `scaledToFill`
        // overflows by design; clip it to the tile before anyone rounds it.
        .clipped()
        .task(id: item.id) {
            // Recycled tiles reuse this view for a new item; drop the previous
            // item's art immediately so it never lingers (or stays forever when
            // the new item has no candidates) -- fall back to the flat tile
            // until the new load resolves.
            image = nil
            guard let (urls, cacheKey) = WADArtwork.candidates(for: item, library: library) else { return }
            let loaded = await WADArtwork.titleImage(candidates: urls, cacheKey: cacheKey)
            // `.task(id:)` cancels the previous task when `item.id` changes,
            // but the detached decode inside `titleImage` isn't itself
            // cancelled -- without this guard a slow, now-stale load could
            // still win the race and briefly flash the previous item's art.
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
