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
    /// Width-to-height ratio of the shape the art fills: 4:3 on tiles, the
    /// art's own ~1.6:1 on the full-width hero (`Theme`).
    var aspectRatio: CGFloat = Theme.tileAspectRatio
    /// When set, the art fills a box of exactly this height at whatever width
    /// is offered and crops to it, instead of deriving its height from
    /// `aspectRatio`. The hero passes `ShelfHeroLayout.artHeight` so a short
    /// viewport still has room for the grid; tiles leave it nil and keep the
    /// ratio.
    var height: CGFloat?

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
                if height != nil {
                    // The capped path letterboxes (spec §5, amended
                    // 2026-08-21): filling a short box used to crop TITLEPIC
                    // to a horizontal band — on a landscape phone the hero
                    // became an unreadable smear, which defeats the one thing
                    // an art-forward hero is for. The whole image now fits the
                    // capped height, centred over a dimmed blur of itself
                    // filling the rest of the width. When the cap is not
                    // binding, fit and fill coincide and the blur is invisible
                    // — portrait renders exactly as before.
                    Image(decorative: artImage, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 24)
                        .opacity(0.45)
                    Image(decorative: artImage, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(decorative: artImage, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
            }
        }
        .modifier(ArtShape(aspectRatio: aspectRatio, height: height))
        // `scaledToFill` can still overflow the frame it is given, so clip it
        // before anyone rounds it. On a 4:3 tile what overflows is only the gap
        // between TITLEPIC's stored 8:5 pixels and the 4:3 Doom displays them
        // at — 83% of the width survives, against 47% while tiles were 3:4.
        // Closing the last 17% would mean drawing the art aspect-corrected
        // rather than filling with it; see `PlayableTileLayout`.
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

    /// Sizes the art either by ratio or by an explicit height. Which branch a
    /// given call site takes is fixed by that call site -- the hero always
    /// passes a height, tiles never do -- so this never flips underneath a
    /// live view.
    private struct ArtShape: ViewModifier {
        let aspectRatio: CGFloat
        let height: CGFloat?

        @ViewBuilder
        func body(content: Content) -> some View {
            if let height {
                // The offered width, at exactly this height. `scaledToFill`
                // inside already overflows a short box, so the art crops --
                // where `aspectRatio(_:contentMode: .fit)` would letterbox
                // instead, shrinking the hero's width to match its capped
                // height and leaving it floating in the middle of the screen.
                content.frame(maxWidth: .infinity).frame(height: height)
            } else {
                content.aspectRatio(aspectRatio, contentMode: .fit)
            }
        }
    }
}
