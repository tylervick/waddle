#if DEBUG
import SwiftUI

/// Canvas fixtures for the two screens `ShelfPreviews` does not cover — the
/// game page and Control Feel — at the default text size and at
/// `.accessibility3` (issue #216).
///
/// `.accessibility3` rather than the largest size for the same reason the
/// shelf previews use it: it is the first size past `isAccessibilitySize`, so
/// it is where the layout's *decisions* change rather than merely where text
/// gets taller.
///
/// Only the game page has a computed layout floor of its own
/// (`PlayableDetailLayout`, pinned by `AccessibilityTextSizeLayoutTests`).
/// Control Feel is a stock `Form` that SwiftUI reflows on its own, so there is
/// no arithmetic to assert about it — which is exactly why it needs an eye
/// instead, per
/// `docs/learnings/geometry-tests-cannot-see-the-screen.md`. Control Feel is
/// the one to look hardest at: `docs/learnings/swiftui-menu-cannot-host-sliders.md`
/// records that its slider rows already could not live in a `Menu`, and a
/// slider with an accessibility-size label is the tightest row in the app.
@MainActor
private enum ScreenPreviewFixture {
    /// The first bundled base game, wrapped for the game page.
    static func firstBaseGame() -> (game: Game, library: LibraryService)? {
        let fixture = ShelfPreviewFixture.continueHero()
        guard let game = try? fixture.library.shelfGames().first(where: \.isBaseGame) else { return nil }
        return (game, fixture.library)
    }

    /// A duplicate of the first bundled base game, wrapped for the game
    /// page — the variant with a base picker offering something other than
    /// "locked", file rows in its load order, and a Delete (not Hide) footer.
    static func firstModdedGame() -> (game: Game, library: LibraryService)? {
        let fixture = ShelfPreviewFixture.continueHero()
        guard let base = try? fixture.library.shelfGames().first(where: \.isBaseGame),
              let copy = try? fixture.library.duplicate(base)
        else { return nil }
        return (copy, fixture.library)
    }
}

/// A host matching `ContentView`'s: the game page is pushed, so without a
/// stack its toolbar has nowhere to land.
private struct GamePagePreviewHost: View {
    var body: some View {
        if let fixture = ScreenPreviewFixture.firstBaseGame() {
            NavigationStack {
                GamePageView(game: fixture.game,
                             library: fixture.library,
                             onPlay: { _, _ in },
                             onChanged: {},
                             onClose: {})
            }
            .preferredColorScheme(.dark)
        } else {
            Text("No bundled base game in the preview fixture")
        }
    }
}

// MARK: - Game page
//
// The one screen here with arithmetic behind it: the header art is capped
// against the viewport so the controls below it stay reachable, and the
// caption it is capped against grows with Dynamic Type.

#Preview("Game page") {
    GamePagePreviewHost()
}

#Preview("Game page, accessibility3") {
    GamePagePreviewHost()
        .dynamicTypeSize(.accessibility3)
}

/// Short viewport plus large text — where the art cap actually binds, the same
/// pairing that matters on the shelf.
#Preview("Game page, landscape, accessibility3", traits: .landscapeLeft) {
    GamePagePreviewHost()
        .dynamicTypeSize(.accessibility3)
}

/// Same host as `GamePagePreviewHost`, over a duplicated (modded) game
/// instead of a base one.
private struct ModdedGamePagePreviewHost: View {
    var body: some View {
        if let fixture = ScreenPreviewFixture.firstModdedGame() {
            NavigationStack {
                GamePageView(game: fixture.game,
                             library: fixture.library,
                             onPlay: { _, _ in },
                             onChanged: {},
                             onClose: {})
            }
            .preferredColorScheme(.dark)
        } else {
            Text("No modded game in the preview fixture")
        }
    }
}

#Preview("Game page, modded") {
    ModdedGamePagePreviewHost()
}

#Preview("Game page, modded, accessibility3") {
    ModdedGamePagePreviewHost()
        .dynamicTypeSize(.accessibility3)
}

// MARK: - Control Feel
//
// Stock `Form` rows, but each pairs a label with a `Slider`, which is the
// combination most likely to crowd at an accessibility size.

#Preview("Control Feel") {
    ControlFeelView()
        .preferredColorScheme(.dark)
}

#Preview("Control Feel, accessibility3") {
    ControlFeelView()
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility3)
}
#endif
