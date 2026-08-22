# Launcher UX design — game-first shelf, two doors, dark shell

**Date:** 2026-08-13
**Status:** Approved design, pending decomposition
**Context:** #121. Grew out of the 2026-08-13 parity audit (#111–#120), which
compared WADdle against the per-game apps it replaces (tomkidd DOOM-iOS
lineage: DOOM, DOOM II, Final DOOM, SIGIL) and found the shell is the largest
unstated gap: the predecessor is game-first — RESUME GAME is the first button
on the first screen, everything is one level deep, each app wears its game's
art — while WADdle's shell is a neutral two-tab library manager that happens
to launch games.

## 1. Principles

1. **The returning player wins the default experience.** When a design
   decision favors the long-time player of the predecessor apps (never
   imports a file, plays the same games for years) at the expense of the
   WAD-library power user, the returning player wins. Power users are assumed
   capable of finding a Manage door; the returning player is never assumed to
   open one.
2. **One screen from launch to playing.** Pick a game, play. Resume is one
   tap.
3. **Management exists but is never in the primary path.**
4. **The shell is always-dark, game-art-forward, native underneath.**

This spec covers the launcher shell only — everything outside a running
engine session. In-game behavior (Woof menus, touch overlay, keyboard) is
untouched, as are the services underneath (`LibraryService`, `ImportService`,
`WADStore`, save handling). This is a view-layer reorganization, not a
data-model change, with one additive exception (§5, `isHidden`).

## 2. The Shelf (home screen)

One `NavigationStack`, no `TabView`. Three zones, top to bottom:

**Continue hero.** The last-played item, full-width: title art, game name,
relative date ("yesterday"). One tap resumes its newest save via the engine's
existing `-loadgame` argument (#112's mechanism). Shown only when a
last-played item with at least one save exists. Otherwise the zone is empty —
or shows the first-launch welcome card (§4).

**The shelf.** Every playable item as one adaptive grid of art tiles: base
games and presets mixed, no section headers, no "Base game"/"Preset"
subtitles. Identity comes from #118's recognized titles plus TITLEPIC art.
Ordering: recently played first, then the rest alphabetically — a returning
player's games self-organize to the front, and Freedoom naturally recedes
once real games arrive.

**Chrome.** A gear (player settings) and a Manage door (§3). Nothing else.

**Tile interactions:**

- **Tap, item has saves:** compact action sheet — **Continue / New Game /
  Details**. This is the predecessor's RESUME/NEW split, translated per-game.
- **Tap, no saves:** straight to the engine title screen, as today.
- **Long-press (any tile):** Continue / New Game / Details / Remove from
  Shelf.
- **Details** is today's `PlayableDetailView` (saves list, control-scheme
  override, create-preset-from-this), reached only through these affordances.

**Amended 2026-08-21** (design pass): two changes to what the grid contains.
The hero's game no longer repeats as a tile — "every playable item" becomes
*every playable item the hero zone is not already presenting* (`Shelf.gridItems`).
Before this, a returning player's screen led with the same game twice, huge
and then again as the first tile directly beneath itself. Nothing is lost:
the hero now carries the same long-press context menu a tile has, so New
Game, Details and Remove stay one gesture away on the hero itself. And while
the library holds fewer than four items, the grid ends with a ghost **Add
Games** tile (`Shelf.showsAddHint`) — same slot and shape as a real tile,
drawn as a dashed outline, same action as **Add Your Games** — so a
near-empty shelf reads as an invitation rather than abandoned space. It
disappears once real games occupy the room.

## 3. The two doors

**Gear — player settings, as a sheet.** Holds what the Play-tab gear menu
scatters today: Touch Controls scheme picker, Control Feel sliders, Show
Debug Info, About. Deliberately small. Future player-facing settings (e.g.,
an auto-use toggle if #114 grows one) land here — this is the successor to
the predecessor's first-class SETTINGS menu.

**Manage — the library workspace, as a full-screen push.** A place you work,
not a quick errand. Absorbs everything currently top-level: the Library list
with its Base Games / Mods / Patches sections (the taxonomy lives here, where
it is useful, and nowhere else), Import, preset creation (the "+" currently
on the Play tab), preset editing (`LoadoutEditorView`), status badges, Show
in Files, delete with the in-use guard. Plus one new list: **Hidden from
Shelf**, with a Restore action per item.

**Shared-component rule:** the Details page reached from a tile is the same
`PlayableDetailView` reached from Manage. One component, two entrances; no
screen exists twice.

## 4. First launch, and the Freedoom decision

**First launch:** the hero zone shows a welcome card — app name, one line,
and a primary **Add Your Games** button opening the standard importer
(multi-select, zip-capable; exactly today's machinery). The Freedoom tiles
are already on the shelf below, so the app remains playable in one tap with
zero setup — the predecessor's most load-bearing property. The welcome card
shows only while the library is factory-state: it disappears once any
non-bundled item exists or any save exists (whichever comes first), and the
zone thereafter shows the Continue hero when §2's rule is met, else nothing.
The AirDrop/share-sheet import path needs no design change; it already works
before the app is first opened.

**Amended 2026-08-21** (design pass): the card no longer carries the app
name. The navigation title directly above it already says "Waddle", and a
first launch greeted the player with the name twice in a row. The card is
now the one-line tagline over the button; the compact form — what remains on
a viewport too tight for the tagline (`welcomeCardShowsDescription`) — is
the button alone. A side effect worth recording: the shorter card fits with
its tagline in far more geometries, including every supported portrait
iPhone at accessibility text sizes except within a few points of the fold
boundary on the 360 pt mini.

**Freedoom presence, resolved** (closes the 2026-07-31 onboarding thread by
deciding all three mechanisms it weighed):

- **Visible by default, no first-launch interrogation.** The returning
  player never answers questions before playing.
- **Per-tile "Remove from Shelf", reversible — yes.** Implemented as an
  `isHidden` flag on the library row. The row, file, and saves all persist;
  that persistence is load-bearing, because
  `LibraryService.seedBundledContentIfNeeded()` re-inserts *missing* bundled
  rows under fresh UUIDs (orphaning saves) — a hidden row is not missing.
  The bundled-delete guard (`LibraryError.wadIsBundled`) and its test stay
  untouched. Hidden items are listed in Manage → Hidden from Shelf with
  Restore.
- **Download-on-first-launch — no.** The app is deliberately no-network
  (README, PRIVACY.md, and the export-compliance answer all lean on it).
- **On-Demand Resources — no.** Byte-reclaim of the bundled 55 MB is not
  worth adding a "not downloaded" state to every flow and an App
  Store-hosted download dependency.

## 5. Visual system

**Always dark, by design.** The engine the shell hands off to is dark; a
light launcher would flash between worlds. No light variant. Semantic colors
defined once in the asset catalog: near-black background, one elevated
surface tone for cards and sheets, a single accent for primary actions
(Continue, Add Your Games) — Freedoom's nukage green `#77FF6F`, matching the
app icon — warm gray secondary text.

**Amended 2026-08-17** (`2026-08-17-icon-wordmark-design.md`): the accent was
red `#CC2C20` until the icon became a Freedoom wordmark. The structure of this
commitment is unchanged — still one accent, still worn by exactly these two
controls. The value changed for contrast as much as coherence: the red measured
3.63:1 as text on the near-black background (AA-large only), the green measures
14.98:1. Because the green is light, anything that *fills* with it needs a dark
label — the Add Your Games button forces black, where white would be 1.29:1.
The rule against retro chrome below governs the shell, not the icon.

**Tiles carry the identity.** TITLEPIC art (existing `TitleArtView` decode)
on 3:4 tiles, title on a bottom scrim, one shared corner radius. Items with
no decodable art get a flat dark tile with the title — no fake art. Presets
wear their IWAD's art.

**Amended 2026-08-18** (#199): tiles are **4:3**, not 3:4. The portrait shape
was chosen without weighing it against the art it holds: TITLEPIC is landscape,
so `scaledToFill` centre-cropped it and only the middle **47%** of each image
was ever visible — usually straight through the wordmark that identifies the
game. The fraction came from the aspect mismatch alone, so it was identical at
every tile size and no column-count fix could touch it. 4:3 is the aspect Doom
*displays* TITLEPIC at rather than the 8:5 its 320×200 pixels are stored as:
tapping a tile launches Woof, which renders that art aspect-corrected, so the
tile now looks like the game it launches. This is the first place the project
takes a position on pixel aspect at all.

Two things were traded for it, both knowingly. **The title stays on the scrim
and is now limited to one line**, so long preset names — "Freedoom Phase 2 +
SCYTHE" — truncate. Moving the title below the art was considered and rejected:
it would undo the on-art scrim this section introduced, and would restructure
the no-art fallback tile, which relies on the scrim to place its title. The
truncation does not reach VoiceOver, whose label sits on the wrapping `Button`
and replaces the tile's contents. **The scrim also had to shrink** — it does not
scale with the tile, and at 4:3 a two-column iPhone tile is 172 × 129 pt, where
the old 60 pt scrim covered 47% of the card for one line of text. It is now
capped at 40% of the tile height at one line, held by `PlayableTileLayout` and
pinned by `PlayableTileLayoutTests`.

**Amended 2026-08-21** (design pass): five visual corrections, found the day
the shelf first rendered in an Xcode canvas rather than through geometry
assertions. **Containment:** the "no padding between tiles" complaint turned
out to be a rendering defect, not a spacing value — `TitleArtView`'s
`scaledToFill` bitmap negotiated each tile's size past its grid cell
(measured: ~190 pt of tile in a 175 pt cell), so every tile painted over the
gap beside it and no gap constant could help. The surface color now owns the
tile's shape alone and the art draws as an overlay, which cannot influence
layout; `PlayTabTests/testTilesStayInsideTheirGridCells` measures the live
hierarchy so this cannot silently return. **Rhythm:** beneath that defect
the screen also sat on one uniform 16 pt beat — outer padding, grid gap,
card padding all equal — which reads as no spacing even when rendered
correctly; the grid gap is now 20 pt and the zone break (`sectionSpacing`)
32 pt, so the intervals form a scale. **Edges:** every art tile wears a 1 pt white
hairline at 12% (`Theme.tileHairline*`) and the shared corner radius is
16 pt; edge-to-edge art on a near-black page has no boundary of its own, and
without one, adjacent tiles read as a single continuous poster whatever the
gap. **Scrim:** the two-stop 0→0.85 gradient put the title's baseline in its
thin half, printing type straight onto the art's own wordmark; the ramp is
now weighted (0 → 0.75 at 55% → 0.92) so the text has a bed. Same height,
same 40% ceiling. **The capped hero letterboxes:** filling a short box
cropped TITLEPIC to an unreadable band on landscape phones, defeating the
art-forward premise exactly where the cap binds; the whole image now fits
the capped height over a dimmed blur of itself, and where the cap is not
binding, fit and fill coincide — portrait is pixel-identical.

**Native underneath.** SF type with Dynamic Type respected — the grid drops
columns at accessibility sizes rather than shrinking text. 44 pt minimum
targets. VoiceOver labels on tiles ("DOOM II, last played yesterday").
Standard sheets and context menus. No custom fonts, no custom controls, no
licensed or retro chrome. iPhone and iPad share the structure; the grid is
adaptive and the hero spans the width.

## 6. Migration and technical notes

- `ContentView` drops the `TabView` for one `NavigationStack` on `ShelfView`
  (today's `PlayView`, restructured).
- `LibraryView` becomes the Manage destination. The gear menu becomes a
  settings sheet. Preset creation's entry moves into Manage.
- Services, import machinery, save handling, and `UserDefaults` keys are
  untouched.
- The only model change is additive: `isHidden` (default false) on library
  rows, plus seeder-respects-hidden.
- Tile accessibility identifiers stay stable so existing UI tests keep
  launching sessions the same way.

## 7. Testing

Existing service tests are unaffected; UI tests re-point to the shelf. New
coverage, all hermetic:

- Shelf ordering: recently played first, then alphabetical.
- Hero visibility: only when a last-played item with at least one save
  exists.
- Hide/restore round-trip, including the seeder not resurrecting a hidden
  bundled row.
- Tap behavior resolving to the action sheet (item with saves) vs. straight
  launch (no saves).
- Welcome-card visibility: factory-state yes; after a non-bundled import or
  any save, no.

No snapshot-test infrastructure: a new dependency, disproportionate here.
Visual judgement is exercised where it already lives — the owner gates every
PR.

## 8. Decomposition and sequencing

Prerequisites already filed: **#112** (Continue via `-loadgame`) and **#118**
(known-IWAD identity) land first; the shelf consumes both.

Issues this spec spawns, in landing order:

1. `isHidden` + Remove from Shelf / Restore + seeder respect — `size:s`,
   agent:eligible, independent of everything else.
2. Shelf restructure: hero, unified grid, tap/sheet/long-press, two doors —
   `size:m`, agent:eligible.
3. Dark-theme pass: semantic colors, tile treatment — `size:s`,
   agent:eligible; the owner judges the look on the PR.
4. First-launch welcome card — `size:s`, agent:eligible, after the shelf.
5. README description + screenshot refresh — agent:blocked (screenshots are
   owner-gated).

#121 closes when these are filed, per its Definition of done.

## 9. Out of scope

- Any in-game change (engine menus, touch overlay, keyboard input).
- A simple/advanced mode toggle — one UI, organized so both audiences fit.
- Custom retro chrome, custom fonts, licensed art. The predecessor's menu
  art was id's and cannot appear in this repo.
- Touch-layout customization (#115's own thread).
- iCloud, accounts, sync, any network feature.
- On-Demand Resources / bundled-content byte reclaim (decided against, §4).
