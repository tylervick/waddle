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

## 8. Slice 3 (2026-10-01): the game page in landscape

Stacking the art over the caption on a page that is wider than it is tall
left the art on its 96 pt floor on every landscape phone, and a wide
letterboxed band on a landscape iPad. Once the viewport is measured and
`contentWidth > viewportHeight`, the hero row puts the art beside the caption
instead: the art takes up to half the row at TITLEPIC's shape, shrinks only
so one tap target of the first section still shows, and never goes below the
floor; the title and the two buttons take the rest. Portrait and the
unmeasured first frame stay stacked, so nothing about the portrait page
changes. `PlayableDetailLayout.arrangement`, `sideBySideArtHeight` and
`sideBySideArtWidth` hold the rule and `PlayableDetailLayoutTests` pins it.

The shelf's landscape iPad hero was looked at and left alone:
`ShelfHeroLayoutTests.testLandscapePadIsCappedButStillDominant` records that
its dominance is a decision, not an accident.

## 9. Slice 4 (2026-10-02): the shelf on a landscape phone, and the chrome it is budgeted against

Measuring the shelf's safe-area chrome on the live view (iPhone 17 Pro, iOS
27) gave 116 pt above and 34 below in portrait and 78 / 20 with 62 pt sides
in landscape. The layout suites had budgeted 96 + 34 and 44 + 21 with 59 pt
sides — a large-title bar the shelf stopped using when the wordmark made it
inline in §5, and an inline bar assumed to be shorter than the large one
when on this runtime it is taller. Every phone fold budget was 20 pt
optimistic in portrait and 33 pt in landscape; the pad fixtures were already
the harder reading and stay. The fixtures now carry the measured numbers.

On those numbers, the stacked landscape-phone hero was on its 96 pt floor at
the default text size, the first tile row peeked under a tap target at
accessibility sizes, and the compact welcome card left the row 40.6 pt clear
of the fold. So a landscape phone — UIKit's compact vertical size class, and
nothing else; the landscape pad keeps its stacked, dominant hero — now lays
the hero zone side by side, as the game page does in §8: the art takes up to
half the row at TITLEPIC's shape, shrunk only so `minimumGridPeek` of the
first row still shows, never below the floor; the title and Continue line sit
beside it. The welcome card puts its tagline beside the button, which costs
no more height than the button alone, so the tagline is kept there rather
than dropped. The zone break in compact height is the grid gap (20) rather
than the 32 pt rhythm break, which on a 304 pt viewport was a tenth of the
screen. `ShelfHeroLayout.arrangement`, `sectionSpacing(compactHeight:)`,
`sideBySideArtHeight/Width/HeroHeight` and `welcomeCardHeight(compactHeight:)`
hold the rules; `ShelfHeroLayoutTests` and `AccessibilityTextSizeLayoutTests`
pin them.
