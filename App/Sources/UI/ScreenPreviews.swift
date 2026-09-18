#if DEBUG
import SwiftUI

/// Canvas fixtures for the three screens `ShelfPreviews` does not cover — the
/// detail page, the preset editor and Control Feel — at the default text size
/// and at `.accessibility3` (issue #216).
///
/// `.accessibility3` rather than the largest size for the same reason the
/// shelf previews use it: it is the first size past `isAccessibilitySize`, so
/// it is where the layout's *decisions* change rather than merely where text
/// gets taller.
///
/// Only the detail page has a computed layout floor of its own
/// (`PlayableDetailLayout`, pinned by `AccessibilityTextSizeLayoutTests`). The
/// preset editor and Control Feel are stock `Form`s that SwiftUI reflows on its
/// own, so there is no arithmetic to assert about them — which is exactly why
/// they need an eye instead, per
/// `docs/learnings/geometry-tests-cannot-see-the-screen.md`. Control Feel is
/// the one to look hardest at: `docs/learnings/swiftui-menu-cannot-host-sliders.md`
/// records that its slider rows already could not live in a `Menu`, and a
/// slider with an accessibility-size label is the tightest row in the app.
@MainActor
private enum ScreenPreviewFixture {
    /// The first bundled base game, wrapped for the detail page.
    static func firstBaseGame() -> (game: Game, library: LibraryService)? {
        let fixture = ShelfPreviewFixture.continueHero()
        guard let game = try? fixture.library.shelfGames().first(where: \.isBaseGame) else { return nil }
        return (game, fixture.library)
    }
}

/// A host matching `ContentView`'s: the detail page is pushed, so without a
/// stack its toolbar has nowhere to land.
private struct DetailPreviewHost: View {
    var body: some View {
        if let fixture = ScreenPreviewFixture.firstBaseGame() {
            NavigationStack {
                PlayableDetailView(game: fixture.game,
                                   library: fixture.library,
                                   onPlay: { _, _ in },
                                   onEdit: { _ in },
                                   onChanged: {})
            }
            .preferredColorScheme(.dark)
        } else {
            Text("No bundled base game in the preview fixture")
        }
    }
}

private struct EditorPreviewHost: View {
    var body: some View {
        NavigationStack {
            LoadoutEditorView(library: ShelfPreviewFixture.factory().library,
                              existing: nil,
                              seedIWAD: nil)
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Detail page
//
// The one screen here with arithmetic behind it: the header art is capped
// against the viewport so the controls below it stay reachable, and the
// caption it is capped against grows with Dynamic Type.

#Preview("Detail page") {
    DetailPreviewHost()
}

#Preview("Detail page, accessibility3") {
    DetailPreviewHost()
        .dynamicTypeSize(.accessibility3)
}

/// Short viewport plus large text — where the art cap actually binds, the same
/// pairing that matters on the shelf.
#Preview("Detail page, landscape, accessibility3", traits: .landscapeLeft) {
    DetailPreviewHost()
        .dynamicTypeSize(.accessibility3)
}

// MARK: - Preset editor

#Preview("Preset editor") {
    EditorPreviewHost()
}

#Preview("Preset editor, accessibility3") {
    EditorPreviewHost()
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
