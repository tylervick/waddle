# Design system — tokens, components, and the game page

Design pass over the SwiftUI shell. Extends the visual system in
`2026-08-13-launcher-ux-design.md` §5 (always dark, art-forward, native
underneath) rather than replacing it. The shelf was the only screen that was
ever *designed*; every other screen is a stock `Form` or `List` with the
background swapped, and the screens had already begun to disagree with each
other — two secondary-text colours, three button treatments, ad-hoc badge
colours, a Play button whose white-on-green label the spec itself measures at
1.29:1.

## 1. Direction

Mostly **the art**, with one **mark**. TITLEPIC gives each screen its colour:
the game page opens on the art with its own colours blurred behind the
controls, and later screens get the same card and type treatment. The shell
itself stays SF type and system controls. The single retro element is the
Freedoom wordmark, which replaces the plain "Waddle" navigation title on the
shelf and ties the shell to the icon. Nothing else in the shell is pixel art.

Spec §5's "no custom controls" is kept in substance: screens that edit things
keep `List`/`Form` for reorder, swipe-to-delete and edit mode. What changes is
that the *styling* of those containers, and of the buttons and badges inside
them, comes from one place.

## 2. Tokens (`Theme.swift`)

Extend `Theme`; keep the four existing colorsets; do not change any shelf
number (its layout tests pin them).

**Typography** (`Theme.Typography`): SF, Dynamic Type, no custom fonts.

| Role | Style | Used by |
|---|---|---|
| `heroTitle` | title2 bold | shelf hero, game page title |
| `tileTitle` | headline | tile scrim |
| `sectionHeader` | subheadline semibold | every list section header |
| `button` | body semibold | the two button styles |
| `secondary` | subheadline | captions, last-played lines |
| `caption` | caption | role labels, file sizes |
| `badge` | caption2 bold | status badges |
| `mono` | footnote monospaced | build info, debug readouts, licenses |

**Spacing** (`Theme.Spacing`): `xs` 4, `sm` 8, `md` 12, `base` 16, `grid` 20,
`section` 32. The shelf's existing 16/20/32 become these names.

**Colours**: three additions, each a universal colorset with no light variant.

- `appWarning` — warm amber `#FFB340`. "Needs a base game" and "no base". Today
  that badge wears the accent, which §5 reserves for primary actions; a warning
  must not look like a Play button.
- `appDanger` — `#FF5A4F`. Missing files and destructive emphasis, replacing
  bare `.red` and the 35 % red capsule in Files.
- `appHairline` — white at 12 %, which the tile already uses by number.

Plus `Theme.onAccent = .black`, the one place the "light accent needs a dark
label" rule lives. `.secondary` is retired in favour of `appSecondaryText`
wherever a file is touched.

**Shape**: one radius, 16, as now. Buttons and cards share it; badges are
capsules.

**Wordmark**: `Theme.wordmarkHeight = 30`. Integer device pixels per source
pixel on both @2x (4) and @3x (6); the glyphs are 15 px tall. Any other height
blurs the pixel face.

## 3. Components (`App/Sources/UI/`)

- `WaddleButtonStyle` — `.waddlePrimary` (accent fill, `onAccent` label) and
  `.waddleSecondary` (surface fill, hairline, white label). Both: `button`
  type, 44 pt minimum, full width, shared radius, 40 % opacity when disabled.
- `StatusBadge(text, tone:)` — capsule, `badge` type, black label; tones
  `.warning`, `.danger`, `.neutral` (surface fill, white label).
- `EmptyStateView(systemImage, title, hint?)` — compact icon + text row in
  `appSecondaryText`, usable inside a list row or on its own.
- `ArtBackdropView(game, library)` — the game's TITLEPIC, blurred and dimmed,
  fading into `appBackground` by roughly 45 % of its height. Decoded through
  `WADArtwork` like `TitleArtView`, so it costs nothing extra once the art is
  cached.
- `View.waddleCard()` — `base` padding, surface fill, shared radius, hairline.
- `View.waddleSectionHeader(_:)` — `sectionHeader` type, `appSecondaryText`,
  no uppercase transform.
- `DesignSystemPreviews.swift` — one canvas per component, in both states where
  there are two, so the system has an eye on it
  (`docs/learnings/geometry-tests-cannot-see-the-screen.md`).

## 4. The game page

Stays a `Form` (reorder and swipe-delete on the file list). The header leaves
the grouped-row treatment and becomes a hero row: zero row insets, clear row
background, no separator.

```text
┌──────────────────────────────┐  ← ArtBackdropView, full bleed, behind the list
│ ╭──────────────────────────╮ │
│ │   TITLEPIC, radius 16,   │ │  inset Spacing.base each side, hairline
│ │   hairline               │ │
│ ╰──────────────────────────╯ │
│ Freedoom Phase 1  ✎          │  heroTitle; tap renames (unchanged)
│ ┌──────────┐ ┌─────────────┐ │  ViewThatFits: side by side, stacked at
│ │ Continue │ │  New Game   │ │  accessibility sizes. Primary / secondary.
│ └──────────┘ └─────────────┘ │  Without a save: one primary "Play".
├──────────────────────────────┤
│ BASE GAME                    │  waddleSectionHeader
│ ┌──────────────────────────┐ │
│ │ Base      Freedoom Ph 2 ⌃│ │  rows unchanged
```

The art keeps the Form's own row inset (`rowHorizontalInset`, 16) on each side
rather than going full bleed, and adds none of its own, so it sits flush with
the cards below: the shelf's hero shares an edge with its grid the same way,
and a page that bleeds where the shelf does not would be a second hero
treatment. The backdrop is what bleeds.

**Viewport measurement (found during this pass).** Both the shelf and the game
page measured their viewport as `proxy.size.height` minus the safe-area
insets. `proxy.size` already excludes them, so both budgets ran 150 pt short
on an iPhone 17 Pro and the game page's art was capped (and letterboxed) in
portrait where it had room. Both now use `proxy.size` alone;
`docs/learnings/geometry-proxy-size-already-excludes-safe-area.md` has the
measured numbers.

`PlayableDetailLayout`'s caption model is re-derived for the new header:
`captionTopPadding` 8, `captionSpacing` 12, a button row of
`max(44, line + 2 × 12)`, `captionBottomPadding` 16. It still charges per
button (stacked) even where `ViewThatFits` puts two on one row, which
over-reserves only where portrait is natural-bound anyway. The contract the
tests pin — controls peek, floor, caption charged against the art — is
unchanged.

Section headers go through `waddleSectionHeader`; "No saves yet" becomes an
`EmptyStateView`; the two primary buttons use the new styles, which is what
fixes the contrast bug. Every accessibility identifier and every visible string
is unchanged (`docs/learnings/ui-tests-pin-user-facing-strings.md`).

## 5. The shelf

Two changes only. The welcome card adopts `waddleCard()` (same padding, same
radius, plus the hairline — no measured height changes). The navigation title
becomes the wordmark as a `.principal` toolbar item, display mode inline;
`navigationTitle("Waddle")` stays set so the back button and
`navigationBars["Waddle"]` keep working.

The wordmark is a derived asset like the mark: `Scripts/build-mark.py` lays
"WADDLE" on one line from the committed glyphs (89 × 15 px), tints it the same
way, and writes 1x/2x/3x nearest-neighbour PNGs; `render-icons.sh` syncs them
into `App/Assets.xcassets/WaddleWordmark.imageset`; `check-icons-fresh.sh`
compares them in both modes. The `Image` draws with `.interpolation(.none)`.

Tiles: the "Needs a base game" badge becomes `StatusBadge(.warning)`. Files:
"no base" likewise, and the Missing status uses `appDanger`. These are the
badge component's only consumers, so they move with it.

## 6. Testing

- `ThemeContrastTests` reads the colorsets from `Assets.xcassets` and asserts
  WCAG ratios: black on accent and on warning ≥ 4.5; accent, warning, danger
  and secondary text on `appBackground` and `appSurface` ≥ 4.5. The learning
  the spec already records ("the accent is light, so anything that fills with
  it needs a dark label") becomes executable.
- `PlayableDetailLayoutTests` and `AccessibilityTextSizeLayoutTests` run
  unchanged against the re-derived caption constants.
- `check-icons-fresh.sh` covers the wordmark in both modes.
- The composed screens are checked by eye in the simulator: game page (base
  game with a save, modded game without), shelf with the wordmark, portrait
  and landscape, default and `.accessibility3`.

## 7. Slice 2 (2026-10-01)

Settings, Control Feel, Files, Hidden Games, About, Add to Game, and the
banners in `ContentView` move onto the tokens. Stock `Form`/`List` throughout;
what changes is: every section header goes through `WaddleSectionHeader`,
every empty state through `EmptyStateView`, every caption and secondary line
through the type roles and `appSecondaryText`, and the two floating banners
become `waddleBanner()` capsules (surface tone, hairline) instead of
`thinMaterial`. About gets the wordmark at `Theme.wordmarkHeightLarge` (45,
the other integer-scale height) as its subject, drawn on the page rather than
in a cell. Settings gains a "Controls" header so its three sections read as
Controls / Library / the rest. No identifier or visible string changes
otherwise.
