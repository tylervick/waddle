import SwiftUI

/// A game's TITLEPIC as the colour of the screen behind it (design-system spec
/// §3): blurred past recognition, dimmed, and fading into the page background
/// before the controls start. The art-forward premise, applied to a page
/// whose *content* is a form.
///
/// Decoded through `WADArtwork` exactly as `TitleArtView` does, and against
/// the same cache key, so a page that already shows the art pays nothing to
/// also stand on it. Drawn as a `background`, it takes part in no layout:
/// whatever frame the page gives it, it fills and clips.
///
/// Nothing is drawn while the art is unresolved or absent — a flat tile's
/// page is simply the page background, which is the "no fake art" rule from
/// spec §5 carried through to the backdrop.
struct ArtBackdropView: View {
    let game: Game
    let library: LibraryService

    /// Where the fade reaches the page background, as a fraction of the
    /// backdrop's own height. Just under half: the hero art and title sit in
    /// the coloured part, the first section header on solid ground.
    static let fadeEnd: CGFloat = 0.45

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.appBackground
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 40)
                    .opacity(0.45)
                LinearGradient(
                    stops: [.init(color: Color.appBackground.opacity(0), location: 0),
                            .init(color: Color.appBackground, location: Self.fadeEnd)],
                    startPoint: .top, endPoint: .bottom)
            }
        }
        .clipped()
        // The container's safe area only: the backdrop is the page's canvas
        // under the bars, and the keyboard's region is not part of that.
        .ignoresSafeArea(.container)
        .accessibilityHidden(true)
        .task(id: game.id) {
            image = nil
            guard let (urls, cacheKey) = WADArtwork.candidates(for: game, library: library) else { return }
            let loaded = await WADArtwork.titleImage(candidates: urls, cacheKey: cacheKey)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
