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
        // The bitmap takes no part in sizing. A resizable `scaledToFill`
        // image reports its own filled size upward, and that negotiation let
        // every art tile grow past its grid cell and paint over the gaps —
        // measured 2026-08-21 at ~190 pt of tile in a 175 pt cell, which is
        // the literal mechanism behind "there is no padding between the
        // tiles": each tile's overflow ate the gap beside it, and no gap
        // constant could ever widen what was being painted over. So the flat
        // elevated surface — a color, whose size is exactly what it is
        // proposed, and the floor a failed decode settles on regardless —
        // owns the shape alone, and the art is an overlay, which cannot
        // influence layout and is clipped to the shape's bounds.
        Color.appSurface
            .modifier(ArtShape(aspectRatio: aspectRatio, height: height))
            .overlay { artOverlay }
            // `scaledToFill` still overpaints the bounds it was offered, so
            // clip before anyone rounds it. On a 4:3 tile what overflows is
            // only the gap between TITLEPIC's stored 8:5 pixels and the 4:3
            // Doom displays them at — 83% of the width survives, against 47%
            // while tiles were 3:4. Closing the last 17% would mean drawing
            // the art aspect-corrected rather than filling with it; see
            // `PlayableTileLayout`.
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

    /// The art layers, drawn over the sized surface. An overlay is proposed
    /// exactly the surface's bounds and can never argue about them — and no
    /// layer in here may exceed those bounds either, because a `scaledToFill`
    /// image's oversized node leaks into the *accessibility* frame even under
    /// `.clipped()` (clipping affects drawing, never element frames). That
    /// leak is what made every tile's — and the hero's — reported frame the
    /// bitmap's 8:5 fill box instead of the view: XCUITest measured 210 pt
    /// buttons in 175 pt cells, overlapping by 15 pt, and the EngineSmoke
    /// "not hittable" flake's `{{-84.3, …}, {377.7, 236}}` frame is the same
    /// arithmetic on the hero. So the fill crop happens in Core Graphics
    /// (`croppedToAspect`) and every `Image` here is a plain `resizable()`
    /// stretch or a `scaledToFit` — shapes that never outgrow their proposal.
    @ViewBuilder
    private var artOverlay: some View {
        if let artImage {
            if height != nil {
                // The capped path letterboxes (spec §5, amended 2026-08-21):
                // filling a short box used to crop TITLEPIC to a horizontal
                // band — on a landscape phone the hero became an unreadable
                // smear, which defeats the one thing an art-forward hero is
                // for. The whole image now fits the capped height, centred
                // over a dimmed blur of itself filling the rest of the width.
                // When the cap is not binding, fit and fill coincide and the
                // blur is invisible — portrait renders exactly as before.
                GeometryReader { geo in
                    ZStack {
                        Image(decorative: Self.croppedToAspect(
                                artImage, geo.size.width / max(geo.size.height, 1)),
                              scale: 1)
                            .resizable()
                            .blur(radius: 24)
                            .opacity(0.45)
                        Image(decorative: artImage, scale: 1)
                            .resizable()
                            .scaledToFit()
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            } else {
                Image(decorative: Self.croppedToAspect(artImage, aspectRatio), scale: 1)
                    .resizable()
            }
        }
    }

    /// The centre crop `scaledToFill` would have shown, taken in Core
    /// Graphics so SwiftUI never meets a bitmap wider than its box. On a 4:3
    /// tile this is the same 83%-of-width crop the fill produced — see the
    /// note on `.clipped()` above. `CGImage.cropping` fails only on
    /// degenerate rects; the uncropped image is the honest fallback, costing
    /// at worst the old overflow for one frame of one tile.
    private static func croppedToAspect(_ image: CGImage, _ ratio: CGFloat) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard ratio > 0, w > 0, h > 0 else { return image }
        var cropW = w, cropH = h
        if w / h > ratio { cropW = h * ratio } else { cropH = w / ratio }
        let rect = CGRect(x: ((w - cropW) / 2).rounded(.down),
                          y: ((h - cropH) / 2).rounded(.down),
                          width: cropW.rounded(.down), height: cropH.rounded(.down))
        return image.cropping(to: rect) ?? image
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
