import SwiftUI
import UIKit

/// The shell's visual system (spec §5, extended by
/// `2026-09-30-design-system-design.md`): always dark, art-forward, native
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
/// The type roles and spacing scale (design-system spec §2) extend that rule
/// to every screen: a view that picks `.subheadline` or `12` on its own is a
/// view that will drift from the next one.
enum Theme {
    /// The one shared corner radius (spec §5). Tiles, the hero, cards and
    /// buttons all use this — not a per-view literal.
    static let cornerRadius: CGFloat = 16

    /// The hairline that gives art tiles an edge (spec §5, amended
    /// 2026-08-21). Edge-to-edge art on a near-black page has no boundary of
    /// its own, so adjacent tiles read as one continuous poster no matter how
    /// wide the gap between them is — the stroke, not the gap, is what makes
    /// a tile an object. Cards and secondary buttons wear the same line.
    static let tileHairlineWidth: CGFloat = 1
    static let tileHairlineOpacity: CGFloat = 0.12

    /// Grid tiles are 4:3 (spec §5, amended 2026-08-18), which is the shape
    /// Doom *displays* TITLEPIC at — not the 8:5 its 320×200 pixels are
    /// stored as. Tapping a tile launches Woof, which renders that art
    /// aspect-corrected, so a tile cut to the same 4:3 looks like the game it
    /// launches.
    ///
    /// This was 3:4 portrait, which cost more than it looked: TITLEPIC is
    /// landscape, so `scaledToFill` centre-cropped it into a portrait frame
    /// and left only 47% of each image's width visible — usually straight
    /// through the wordmark that identifies the game. The fraction came from
    /// the aspect mismatch alone, so it was the same at every tile size.
    /// `PlayableTileLayout` holds the arithmetic and the tests that pin it.
    static let tileAspectRatio: CGFloat = 4.0 / 3.0

    /// The hero keeps TITLEPIC's own ~1.6:1 instead: it "spans the width"
    /// (spec §5) rather than being a tile, and cropping a full-width banner to
    /// 3:4 would throw away most of the art it exists to show.
    static let heroAspectRatio: CGFloat = 1.6

    /// 44 pt minimum targets (spec §5). Applies to the controls the shell
    /// draws itself; system chrome (toolbar, sheets, context menus) already
    /// meets this.
    static let minimumTapTarget: CGFloat = 44

    /// The two button styles' padding above and below their label. A button
    /// is the taller of its label plus this and `minimumTapTarget`; the
    /// shelf's welcome card and the game page both budget their height from
    /// this same number.
    static let buttonVerticalPadding: CGFloat = Spacing.md

    /// The label colour for anything filled with `appAccent` or `appWarning`.
    /// Both are light: the accent measures 1.29:1 behind a white label and
    /// 16.32:1 behind a black one (spec §5, amended 2026-08-17). This is the
    /// one place that rule lives; `ThemeContrastTests` checks the catalog's
    /// actual values against it.
    static let onAccent: Color = .black

    /// Height of the shelf's wordmark (design-system spec §5). 30, and not a
    /// rounder-looking number, because the glyphs are 15 px tall and the
    /// image draws without interpolation: 30 pt is 4 device pixels per source
    /// pixel on @2x and 6 on @3x. 20 or 24 would land on a fraction on one
    /// scale or the other and smear the pixel face.
    static let wordmarkHeight: CGFloat = 30

    /// The wordmark on the About screen, where it is the subject rather than
    /// a title. 45 for the same reason 30 is: 9 device pixels per source pixel
    /// on @3x and 6 on @2x, both integers.
    static let wordmarkHeightLarge: CGFloat = 45

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

    /// The content width from which the shelf's grid is on a wide window, and
    /// the tile floor it uses there (issue #353).
    ///
    /// The 150 pt floor above is derived from the narrowest phone, where it
    /// buys a second column. On a wide window the same floor only buys *more*
    /// columns of phone-sized tiles: an open iPhone Duo has 835 pt of content
    /// and got five tiles of 151 pt, too narrow for "Freedoom Phase 1" (which
    /// needs 168) with more than half the row empty. At 190 it gets four tiles
    /// of 194 pt and the titles fit at full size.
    ///
    /// ## Why the threshold is 610
    ///
    /// Not because any device is 610 wide. It is the width at which both
    /// floors resolve to the same three columns — (610 + 20) / (150 + 20) and
    /// (610 + 20) / (190 + 20) both round down to 3 — so crossing it changes
    /// no layout. A threshold of 600 would drop a 600 pt window from three
    /// columns to two tiles of 290 pt, and a window being dragged across it
    /// would jump. `WideGridLayoutTests` pins that there is no jump.
    ///
    /// Everything this repo has measured below 610 keeps the phone floor:
    /// every phone, and the closed Duo in both orientations (344 and 562 pt).
    static let wideGridContentWidth: CGFloat = 610
    static let wideGridMinimumTileWidth: CGFloat = 190

    /// The adaptive grid's minimum tile width for the width the grid actually
    /// has. `contentWidth` is the shelf's measured content width; zero, which
    /// is "not measured yet", takes the phone floor. Accessibility sizes keep
    /// their own, larger floor at every width.
    static func gridMinimumTileWidth(for size: DynamicTypeSize, contentWidth: CGFloat) -> CGFloat {
        guard !size.isAccessibilitySize, contentWidth >= wideGridContentWidth else {
            return gridMinimumTileWidth(for: size)
        }
        return wideGridMinimumTileWidth
    }

    /// The type roles (design-system spec §2). SF with Dynamic Type, no custom
    /// fonts (spec §5). A screen picks a role, never a text style, so two
    /// screens that mean the same thing set it the same way.
    enum Typography {
        /// The shelf hero's and the game page's title.
        static let heroTitle: Font = .title2.bold()
        /// The title on a tile's scrim.
        static let tileTitle: Font = .headline
        /// Every list section header, through `waddleSectionHeader`.
        static let sectionHeader: Font = .subheadline.weight(.semibold)
        /// The label inside the two button styles.
        static let button: Font = .body.weight(.semibold)
        /// Captions and last-played lines.
        static let secondary: Font = .subheadline
        /// Role labels, file sizes.
        static let caption: Font = .caption
        /// The text inside a `StatusBadge`.
        static let badge: Font = .caption2.bold()
        /// Build info, debug readouts, licence text.
        static let mono: Font = .footnote.monospaced()
    }

    /// The spacing scale (design-system spec §2). The shelf's 16/20/32 were
    /// chosen on 2026-08-21 so the intervals form a scale rather than one
    /// uniform beat that reads as no spacing at all; these are those numbers,
    /// named, plus the three smaller steps the components use.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        /// Outer page padding and card padding.
        static let base: CGFloat = 16
        /// The shelf's grid gap.
        static let grid: CGFloat = 20
        /// The break between zones on the shelf.
        static let section: CGFloat = 32
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
    /// a white label. Anything that fills with this colour needs
    /// `Theme.onAccent` — see `WaddlePrimaryButtonStyle`.
    static let appAccent = Color("AccentColor")
    /// Warm amber for a state that needs attention but is not an error: a
    /// game with no base yet. Light like the accent, so it takes
    /// `Theme.onAccent` as its label too.
    static let appWarning = Color("AppWarning")
    /// The one red: a missing file, destructive emphasis.
    static let appDanger = Color("AppDanger")
    /// The hairline (spec §5, amended 2026-08-21) as a colour, for the stroke
    /// tiles, cards and secondary buttons share.
    static let appHairline = Color.white.opacity(Theme.tileHairlineOpacity)
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

    /// A card: the elevated surface, the shared radius, and the hairline that
    /// makes it an object on the near-black page — the same edge the tiles
    /// wear, for the same reason.
    func waddleCard() -> some View {
        padding(Theme.Spacing.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSurface,
                        in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Color.appHairline, lineWidth: Theme.tileHairlineWidth)
            )
    }
}

extension Theme {
    /// The outline of a floating banner. A rounded rectangle with the cards'
    /// radius rather than a capsule: a capsule's ends are half-circles as
    /// tall as the banner, so once the text wraps they cut across its first
    /// and last lines (issue #423). The radius is the same however many lines
    /// there are; a banner under twice the radius tall (the exit label) still
    /// comes out as a capsule, because the shape clamps its radius.
    static var bannerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

extension View {
    /// A floating banner over the shelf: the import notice and the engine's
    /// exit label. `Theme.bannerShape` in the surface tone with the hairline,
    /// so it is an object on the page the way a card is, rather than a smear
    /// of whatever art happens to be under it.
    func waddleBanner() -> some View {
        background(Color.appSurface, in: Theme.bannerShape)
            .overlay(Theme.bannerShape.strokeBorder(Color.appHairline, lineWidth: Theme.tileHairlineWidth))
    }
}

/// A list section's header, the same on every screen: the `sectionHeader`
/// role in the secondary tone, and the text as written rather than the
/// uppercase transform grouped lists apply by default — the copy is already
/// capitalised the way the spec wrote it.
struct WaddleSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(Theme.Typography.sectionHeader)
            .foregroundStyle(Color.appSecondaryText)
            .textCase(nil)
    }
}

/// Children side by side at the ordinary text sizes and one under the other
/// at the accessibility sizes, where two things on one line each get less
/// width than their longest word needs (issue #425).
struct AccessibilityStack<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: spacing) { content }
        } else {
            HStack(spacing: spacing) { content }
        }
    }
}

/// A list row's label: icon and title at the ordinary text sizes, the title
/// alone at the accessibility sizes. In the shelf's panel a row is about
/// 280 pt wide, and at the largest size the icon left "Hidden Games" less
/// than "Hidden" needs, so the word was hyphenated (issue #425). The icons
/// repeat what the titles say; the titles are what has to stay whole.
struct WaddleRowLabelStyle: LabelStyle {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeBody(configuration: Configuration) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            configuration.title
        } else {
            Label(configuration)
        }
    }
}

/// Text that keeps its words whole. Wrapping breaks a word that is wider
/// than its line, and on iOS hyphenates it where it can ("Compatibili-" /
/// "ty", "Eviter-" / "nity II" in the shelf's panel at the largest
/// accessibility size, issue #425). So the text is never handed a line
/// narrower than its widest piece: it is drawn at the largest of a few sizes
/// at which that piece fits its line, and then every break the system makes
/// falls between pieces. Text that fits is drawn as it always was, so this
/// costs nothing at the ordinary sizes.
///
/// A piece is a word, or a part of one that ends at a hyphen or an underscore
/// or starts at a dot: a file's name is usually one unspaced token
/// ("sunlust_final_v13"), and it may wrap at those characters.
///
/// Nothing is ever cut. Shrinking stops at `smallestScale`; where the widest
/// piece does not fit even then, the text is left to wrap as plain text
/// does, broken but all there.
///
/// ## Why the size is chosen here and not by `minimumScaleFactor`
///
/// The first two versions set `lineLimit` to the number of pieces and let
/// `minimumScaleFactor` shrink the text when it ran out of lines, on the
/// reasoning that it only runs out when a piece has been broken. That holds
/// for one piece and fails for two: "Eviter-" / "nity II" is two lines for
/// two pieces, because the broken word's tail shares a line with the next
/// word, so the limit is never reached and nothing shrinks (second review of
/// pull request 435). The system offers no "do not hyphenate" for a SwiftUI
/// `Text`, so the only sure way to keep a word whole is to give it room.
struct WholeWordText: View {
    let string: String
    /// The text style this is drawn in. It is what the widest piece is
    /// measured with, and what the smaller sizes are scaled from.
    var textStyle: UIFont.TextStyle = .body
    /// The weight it is drawn in, for the same two purposes. Like the text
    /// style it describes the caller's font and does not set it: the game
    /// page's title is `.title2.bold()`, and a bold piece is wider than a
    /// regular one (issue #441).
    var weight: UIFont.Weight = .regular
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ string: String, textStyle: UIFont.TextStyle = .body, weight: UIFont.Weight = .regular) {
        self.string = string
        self.textStyle = textStyle
        self.weight = weight
    }

    /// The sizes tried, largest first, as fractions of the text style's own.
    nonisolated static let scales: [CGFloat] = [1, 0.9, 0.8, 0.7, 0.6, 0.5]
    nonisolated static var smallestScale: CGFloat { scales.last ?? 1 }

    /// The parts no line may end inside: split at whitespace, after "-" and
    /// "_", and before ".".
    nonisolated static func pieces(_ string: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        func end() {
            if !current.isEmpty { pieces.append(current) }
            current = ""
        }
        for character in string {
            if character.isWhitespace {
                end()
            } else if character == "." {
                end()
                current.append(character)
            } else {
                current.append(character)
                if character == "-" || character == "_" { end() }
            }
        }
        end()
        return pieces
    }

    /// The string with a zero-width space between the pieces of each word,
    /// which is where a line may end. It draws nothing.
    nonisolated static func wrapping(_ string: String) -> String {
        var result = ""
        var previous: Character?
        for character in string {
            if let previous, !previous.isWhitespace, !character.isWhitespace,
               previous == "-" || previous == "_" || character == "." {
                result.append("\u{200B}")
            }
            result.append(character)
            previous = character
        }
        return result
    }

    /// The text style's font at the reader's size, and the widest piece in
    /// it. Reads the text size from the environment so that a change of it
    /// measures again.
    private var measured: (font: UIFont, widest: CGFloat) {
        _ = dynamicTypeSize
        let font = Self.font(textStyle: textStyle, weight: weight)
        return (font, Self.widestPiece(of: string, in: font))
    }

    /// The text style's font at the reader's size, in `weight`. The regular
    /// weight is the text style's own font, untouched.
    nonisolated static func font(textStyle: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        let preferred = UIFont.preferredFont(forTextStyle: textStyle)
        return weight == .regular ? preferred : .systemFont(ofSize: preferred.pointSize, weight: weight)
    }

    /// SwiftUI's name for a UIKit weight, for the sizes this draws smaller.
    nonisolated static func fontWeight(_ weight: UIFont.Weight) -> Font.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    /// The width of the widest piece of `string` in `font`; zero for a
    /// string with no pieces.
    nonisolated static func widestPiece(of string: String, in font: UIFont) -> CGFloat {
        pieces(string)
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
    }

    var body: some View {
        let text = Self.wrapping(string)
        let (font, widest) = measured
        // `ViewThatFits` takes the first child whose ideal width fits, and
        // each child's ideal width is declared as its widest piece at that
        // child's size. So the choice is the largest size at which no piece
        // is wider than the line.
        ViewThatFits(in: .horizontal) {
            sized(text, widest: widest, font: font, scale: Self.scales[0])
            sized(text, widest: widest, font: font, scale: Self.scales[1])
            sized(text, widest: widest, font: font, scale: Self.scales[2])
            sized(text, widest: widest, font: font, scale: Self.scales[3])
            sized(text, widest: widest, font: font, scale: Self.scales[4])
            sized(text, widest: widest, font: font, scale: Self.scales[5])
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityLabel(string)
    }

    /// The text at one size, saying how wide its widest piece is there. A
    /// point over, because that width is `UIFont`'s measure and the line is
    /// SwiftUI's.
    ///
    /// At full size no font is set at all, so the text is drawn in whatever
    /// font the caller gave it and text that fits is exactly what a plain
    /// `Text` would be. Not `.font(nil)`: that is not "no font", it replaces
    /// the caller's with the default, and the game page's bold title came
    /// out regular (issue #441).
    ///
    /// The text takes the height its lines need, whatever it is offered:
    /// beside the title's pencil in an `HStack` it was offered one line's
    /// height, and a name that wrapped to two was cut with an ellipsis.
    @ViewBuilder
    private func sized(_ text: String, widest: CGFloat, font: UIFont, scale: CGFloat) -> some View {
        let idealWidth = ceil(widest * scale) + 1
        if scale == 1 {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(idealWidth: idealWidth, alignment: .leading)
        } else {
            Text(text)
                .font(.system(size: font.pointSize * scale, weight: Self.fontWeight(weight)))
                .fixedSize(horizontal: false, vertical: true)
                .frame(idealWidth: idealWidth, alignment: .leading)
        }
    }
}
