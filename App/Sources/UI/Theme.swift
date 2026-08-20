import SwiftUI

/// The shell's visual system (spec §5): always dark, art-forward, native
/// underneath.
///
/// The colors live once in the asset catalog and are only *named* here. Each
/// colorset carries a single universal entry with no light/dark appearance
/// qualifier, so it resolves to the same value whatever the system setting is
/// — that, plus the `.preferredColorScheme(.dark)` `ContentView` applies to the
/// whole scene, is what "always dark, no light variant" means in practice. A
/// second appearance added to any of those colorsets would quietly reintroduce
/// the light variant the spec rules out.
///
/// The metrics are here for the same reason: §5 commits to *one* shared corner
/// radius and *one* tile shape, so the shelf, the hero and the fallback tile
/// have to read them from a single place rather than each picking their own.
enum Theme {
    /// The one shared corner radius (spec §5). Tiles, the hero, and anything
    /// else the shell rounds use this — not a per-view literal.
    static let cornerRadius: CGFloat = 14

    /// Grid tiles are 3:4 portrait (spec §5). TITLEPIC art is natively
    /// landscape, so `TitleArtView` fills and crops into this shape rather
    /// than letterboxing it.
    static let tileAspectRatio: CGFloat = 3.0 / 4.0

    /// The hero keeps TITLEPIC's own ~1.6:1 instead: it "spans the width"
    /// (spec §5) rather than being a tile, and cropping a full-width banner to
    /// 3:4 would throw away most of the art it exists to show.
    static let heroAspectRatio: CGFloat = 1.6

    /// 44 pt minimum targets (spec §5). Applies to the controls the shell
    /// draws itself; system chrome (toolbar, sheets, context menus) already
    /// meets this.
    static let minimumTapTarget: CGFloat = 44

    /// The adaptive grid's minimum tile width, which is how the grid "drops
    /// columns at accessibility sizes rather than shrinking text" (spec §5).
    ///
    /// `GridItem(.adaptive(minimum:))` fits as many columns of at least this
    /// width as it can, so raising the floor at accessibility sizes fits fewer
    /// of them into the same screen — and the type inside each tile keeps
    /// whatever size Dynamic Type asked for instead of being squeezed to fit a
    /// column count chosen for smaller text.
    ///
    /// ## Why the standard floor is 150 and not 200
    ///
    /// A floor of 200 resolved to **one** column on every iPhone this app
    /// supports, not just narrow ones: the widest is 440 pt, which leaves
    /// 408 pt of content, and 408 cannot hold two 200 pt columns plus the
    /// 16 pt gap. One column means the first tile row is 3:4 of the full
    /// content width — 544 pt on that widest phone — which is most of the
    /// viewport on its own and is what pushed the row's bottom past the fold.
    ///
    /// The floor is derived from the *narrowest* supported width rather than
    /// the widest, or the one CI happens to run.
    /// `TARGETED_DEVICE_FAMILY` is `"1,2"` and the
    /// deployment target is iOS 26.0, whose simulator runtime admits the
    /// iPhone 12 mini and 13 mini at **360 × 780 pt** — narrower than the
    /// 375 pt iPhone SE, and the real floor. Two columns there need
    /// `(360 − 32 − 16) / 2 = 156` pt or less.
    ///
    /// 150 rather than 156 on purpose: 156 is the exact boundary, where the
    /// adaptive fit evaluates to precisely 2.0 columns and any disagreement
    /// between this arithmetic and SwiftUI's own tips it to one. Landing a
    /// layout decision on an exact boundary is the mistake this constant
    /// exists to undo, so it is not repeated here. The usable window is
    /// roughly 126–156 pt — below 126 the widest phone would gain a third
    /// column — and 150 sits inside it with room on both sides.
    static func gridMinimumTileWidth(for size: DynamicTypeSize) -> CGFloat {
        size.isAccessibilitySize ? 320 : 150
    }
}

extension Color {
    /// Near-black page background (spec §5).
    static let appBackground = Color("AppBackground")
    /// The single elevated surface tone: cards, sheet rows, and the flat
    /// no-art tile.
    static let appSurface = Color("AppSurface")
    /// Warm gray secondary text.
    static let appSecondaryText = Color("AppSecondaryText")
    /// The one accent, reserved for primary actions — Freedoom's nukage green,
    /// matching the app icon. Also the asset catalog's global accent
    /// (`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` in `App/project.yml`),
    /// which is what tints system controls the shell does not draw itself.
    ///
    /// It is light: 14.98:1 as text on `appBackground`, but only 1.29:1 behind
    /// a white label. Anything that fills with this colour needs a dark label —
    /// see the Add Your Games button in `ShelfView`.
    static let appAccent = Color("AccentColor")
}

extension View {
    /// The shared treatment for the shell's scrolling containers — the sheets
    /// and Manage (spec §5's "standard sheets", themed rather than replaced).
    ///
    /// `List`/`Form` paint their own grouped background and row fills, both of
    /// which follow the system appearance; hiding the former and naming the
    /// latter is what puts these screens on the same two semantic tones as the
    /// shelf. `listRowBackground` applied to the container propagates to its
    /// rows, so each screen needs one call rather than one per row.
    func waddleScrollSurface() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .listRowBackground(Color.appSurface)
    }
}
