import SwiftUI

/// Generated placeholder art shown while `TitleArtView` is loading a real
/// TITLEPIC (or when none decodes): a family-accent-colored tile with a
/// monogram derived from the title. Deterministic -- no randomness -- so it's
/// stable across repeated renders of the same item.
struct GeneratedArtView: View {
    let title: String
    let family: GameFamily

    private var accentColor: Color {
        switch family {
        case .doom1: return Color.red.opacity(0.35)
        case .doom2: return Color.orange.opacity(0.35)
        case .unknown: return Color.gray.opacity(0.3)
        }
    }

    /// First character of up to the first two whitespace-separated words of
    /// `title`, uppercased -- e.g. "Freedoom Phase 1" -> "FP".
    private var monogram: String {
        title.split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
            .compactMap { $0.first }
            .map { String($0).uppercased() }
            .joined()
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(accentColor)
            .aspectRatio(1.6, contentMode: .fit)
            .overlay(
                Text(monogram)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.secondary)
            )
    }
}

/// Async-loads a `PlayableItem`'s TITLEPIC art (via `WADArtwork`) and shows
/// `GeneratedArtView` while loading or when no art decodes. Slots into
/// `PlayableTileView` and `PlayableDetailView` in place of their former
/// static placeholder.
struct TitleArtView: View {
    let item: PlayableItem
    let library: LibraryService

    @State private var image: CGImage?

    private var family: GameFamily {
        switch item {
        case .baseGame(let wad):
            return wad.gameFamily
        case .preset(let loadout):
            return (try? library.wad(id: loadout.iwadID))?.gameFamily ?? .unknown
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(1.6, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                GeneratedArtView(title: item.title, family: family)
            }
        }
        .task(id: item.id) {
            guard let (urls, cacheKey) = WADArtwork.candidates(for: item, library: library) else { return }
            image = await WADArtwork.titleImage(candidates: urls, cacheKey: cacheKey)
        }
    }
}
