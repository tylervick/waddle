# Play & Library Rework — Design Spec

**Date:** 2026-07-23
**Status:** Approved (brainstorm), pending implementation plan
**Branch:** `tylervick/rework-play-library-layout`

## Problem

The current UI splits into two tabs — **Play** (a grid of `Loadout` tiles) and
**Library** (a flat `List` of `WADFile`s). The `Loadout` abstraction (IWAD +
ordered PWADs + DEH + complevel + name) is genuinely powerful for enthusiasts,
but it is **too heavy as the mandatory front door**: you must construct a
loadout before you can play, even for "just launch the base game."

Concrete symptoms in today's build:

- **Base games masquerade as presets.** `seedBundledContentIfNeeded()`
  auto-creates a `Loadout` per Freedoom phase, so "play the base game" is
  modeled as a fake, self-resurrecting preset.
- **Preset CRUD is hard to reason about.** *Create* has three doors with
  different behavior (Play `+` blank form, Library leading-swipe auto-create,
  Library context menu). *Read* barely exists — a preset is opaque, inferred
  from a joined subtitle string. *Update* is a heavyweight multi-section modal
  `Form`. *Delete* forks into save-keeping choices with no visibility into what
  saves exist.
- **Play tiles are bare and same-y** — every tile is an identical flame glyph;
  `lastPlayed` is tracked but unused.
- **Library is a dumping ground** — a flat list mixing IWAD/PWAD/DEH behind a
  tiny text badge, disconnected from the on-disk `Documents/WADs/` reality even
  though the app already ships `UIFileSharingEnabled` +
  `LSSupportsOpeningDocumentsInPlace`.

## Design philosophy

We keep the **two-level structure** — playable configs vs. raw files — because
DOOM's playable unit is genuinely *compositional*: a PWAD is a layer that needs
an IWAD underneath, and multiple mods stack with a load order. That
composition is many-to-many and can't be attributed to any single file, which
is exactly what a pure emulator/Delta model (atomic ROM = game, config as a
per-game detail) cannot express. So:

- **Delta-style for the 90%** — tap a thing, it plays; its config lives on a
  per-item **detail page**.
- **Presets are the overflow bucket for the compositional 10%** — saved combos
  that no single tile owns.

The rework's goals: (1) make **simple games one tap**, (2) make **preset CRUD
easy to reason about**, (3) align **Library with the Documents container**,
(4) keep **WAD-title-art thumbnails**, (5) allow **per-item control scheme**.

## Information architecture

Two tabs, unchanged in spirit from today. Global settings stay behind the
existing gear/Settings entry (not a new tab).

- **Play** — where you *launch*. One grid of **playable items** = base games +
  presets, rendered as identical title-art tiles.
- **Library** — where you *manage files*. A view aligned to `Documents/WADs/`
  (+ bundled read-only content).

The word "Loadout" leaves the primary vocabulary; the surviving user-facing
term is **Preset**. The `"Created loadout — find it in Play"` toast is deleted —
there is no more cross-tab indirection to explain.

## Play tab

### The grid

- One `LazyVGrid` of **playable items**: base games (IWADs) and presets, same
  tile visual. A **Recently Played** section sits on top (recency-sorted across
  base games + presets by `lastPlayed`); it does not render until something has
  been played, so first-run shows only the base-games/presets grid.
- **Tile visual:** the WAD's title-screen art (see *Title art* below), with the
  item name beneath. Tap = play.
- **Tap = play.** One tap launches — for a base game this is a vanilla launch;
  for a preset it launches exactly as configured. "Base games one tap" is
  preserved verbatim.
- **Info affordance / long-press → detail page** (below) — the Read/Update/
  Delete surface.
- Toolbar: **`+`** (create preset) and the **gear/Settings** entry (global
  defaults, Control Feel, About).

### The detail page

The single Read/Update/Delete surface for any playable item — base game *or*
preset. Same layout for both; editability differs.

```text
┌─────────────────────────────┐
│   [ title art ]             │
│   <name>            ▶ Play   │
│ ─ Contents ──────────────── │
│   Base: <IWAD>              │   locked for a base game;
│   Mods: <ordered PWADs> ↕   │   editable for a preset
│   Patches: <DEH>           │
│   Compat: <complevel|Auto> │
│ ─ Controls ──────────────── │
│   Layout: ● Default (Modern)│   per-item scheme override
│           ○ Classic  ○ Modern│
│ ─ Saves (N) ─────────────── │
│   ▸ <slot> · <when>   [x]   │   visible save files
│ ─────────────────────────── │
│   [Create preset from this] │   base game only
│   [Delete preset]           │   preset only
└─────────────────────────────┘
```

- **Base game:** `Contents` is **locked** (you can't change what Doom II *is*).
  `Controls` is **editable**. `Create preset from this` graduates it to a full
  preset. No delete (base games are managed in Library).
- **Preset:** fully editable content (base, mods + order, patches, compat),
  editable `Controls`, and `Delete preset` with the **Saves list visible right
  there** so the keep/delete-saves decision has context.

This resolves **base ≠ preset** without a "locked built-in preset" concept:
both share the page, a base game's *content* is fixed while a preset's is
user-authored.

### Preset CRUD (the fix)

- **Create — one door.** `+` in Play → choose a base game to start from →
  detail page opens in edit mode → add mods → **auto-named** (e.g. "Doom II +
  Sunlust", editable). The Library leading-swipe and context-menu auto-create
  paths are **removed**; a Library item's context menu may offer "Create preset
  with this…" that opens the *same* flow pre-seeded. Mental model: *a preset is
  a base game + your changes.*
- **Read** — the detail page.
- **Update** — edit-in-place on the detail page; no heavyweight modal `Form`.
- **Delete** — on the detail page, saves visible.

## Controls: per-item scheme, global feel

Touch controls resolve in **two layers** (`layout × feel`):

- **Layer 1 — Scheme (per item):** `Classic | Modern`, overridable per playable
  item, defaulting to the global default. This is a *layout/mechanism* choice
  (Classic routes turning through the movement stick; Modern uses a separate
  right-side drag-to-turn). Resolved at play time as
  `item.schemeOverride ?? globalDefaultScheme`.
- **Layer 2 — Feel (global only):** `turnSpeed`, `stickDeadZone`,
  `moveSensitivity`. These are *feel dimensions that mean the same thing in
  either scheme* (the existing `TouchTuning` knobs already span both — turn
  speed scales Classic stick-turn *and* Modern drag-turn). They apply to
  whichever scheme Layer 1 resolved to. Feel is about the player's thumbs, so
  it stays consistent across games.

**Rationale for scheme-only per item:** a per-item override that is a single
discrete enum is trivial to store and reason about. A per-item *bundle of
continuous sliders* would demand named, reusable "control presets" — a second
CRUD system layered on the one we just simplified. Therefore:

- Per item: a single **Layout** override (`Default · Classic · Modern`) — the
  entire `Controls` section.
- Global: the Control Feel sliders stay in Settings, unchanged, applied every
  session regardless of scheme.
- **Deferred (YAGNI):** per-item *feel* is an explicit future option. If it is
  ever wanted, *that* is the moment to introduce named control presets — not
  before.

**Implementation note:** the scheme is currently read from `UserDefaults` once
at overlay-install (`OverlayPresenter` / `TouchControlScheme.current`). Per-item
override means `EngineSession.play` resolves `override ?? global` and hands the
**effective** scheme to `OverlayPresenter`, instead of it reading the global key
directly. Localized change; the `WADDLE_TOUCH_SCHEME` debug test-seam and the
global default read are preserved as the fallback path.

## Library tab

A file manager aligned to the on-disk container rather than a parallel DB list.

- Reflects `Documents/WADs/` (+ bundled read-only `GameData/`), grouped by kind
  (**Base games / Mods / Patches**), showing on-disk filename, size, and
  bundled/imported status.
- **Import** (`+` → `fileImporter`, unchanged file types), **delete**
  (reference-guarded exactly as today via `loadoutsReferencing`), and
  **reveal-in-Files** where practical.
- **DB reflects disk.** The SwiftData metadata becomes a reflection of the
  folder: files dropped directly into the container via the iOS Files app are
  **adopted** (the existing loose-file adoption mechanism) and simply appear.
- DEH/BEX patches appear here as files but are **not independently playable**
  (they are modifiers surfaced only inside a preset's `Contents`).

## Title art (thumbnails)

- Extract each WAD's **TITLEPIC** lump (the title screen every DOOM WAD ships)
  and render it as the tile image.
  - Locate the lump via the existing `WADParser`; decode the DOOM patch/picture
    format using the applicable `PLAYPAL` palette (the WAD's own, or the
    resolved base IWAD's when a PWAD ships none). Support a PNG-signature lump
    as a direct decode for ZDoom-style title graphics.
  - **Cache** the decoded thumbnail to disk keyed by `sha1`; decode **lazily and
    off the main thread**. Must never block launch or import — honor the
    existing watchdog/jetsam caution around large WADs (Eviternity II ~293 MB).
- **Fallback** when a PWAD has no TITLEPIC (map-only mods) or decode fails:
  **generated art** — a game-family accent color + monogram/initials — so tiles
  stay distinct without parsing.

## Data model changes

- `WADFile`: add `lastPlayed: Date?` so base games (and any directly-played
  item) feed Recently Played **without** manufacturing a hidden `Loadout`.
- `Loadout` (the preset model): add an optional per-preset **scheme override**
  (`String?` mapping to `TouchControlScheme`, `nil` = use global default).
  `complevel` already exists per-preset.
- Base games need a per-item scheme override too (they are not `Loadout`s).
  Store it keyed by the base `WADFile.id` (a small keyed store, e.g.
  `UserDefaults`/a lightweight model), resolved the same way at play time.
- **Ephemeral launch stays available internally:** tapping a base game builds
  launch args on the fly (that IWAD, auto complevel) and stamps `lastPlayed`;
  no `Loadout` is persisted. Presets launch from their persisted config as
  today.

## Migration

- **Existing `Loadout`s → Presets.** No data migration; they are re-labeled in
  the UI and gain the optional scheme-override field (defaulting to `nil`).
- **Stop auto-creating base-game loadouts.** `seedBundledContentIfNeeded()` no
  longer inserts a `Loadout` per Freedoom phase; it registers only the bundled
  IWAD `WADFile`s. The Freedoom base games appear directly as playable tiles.
  Any previously auto-created "Freedoom Phase 1/2" loadouts are **removed** on
  launch (a one-time reconciliation that deletes bundled-IWAD-only,
  no-PWAD/DEH loadouts whose name matches the seeded phase title), so the base
  game is the single source. User-authored presets are never touched by this
  reconciliation.
- **Preserve test hooks.** UITests currently tap `playFreedoom1` (a loadout
  tile) and switch tabs via `app.tabBars.buttons["Play"|"Library"]` asserting
  `playTab`/`libraryTab`. The `playFreedoom1` identifier moves onto the Freedoom
  base-game tile; the tab identifiers/labels are preserved. The `addPWADMenu` /
  `addPWADButton-<name>` hooks live in the preset editor flow.

## Out of scope / explicitly deferred

- Per-item **control feel** (sliders) and the named "control presets" it would
  require.
- A "play any mod right now without making a preset" quick-launch path (the
  compositional case is served by presets; simple case is base-game one-tap).
- Collapsing to a single surface / removing a tab (considered and rejected — the
  two-level structure is kept).

## Testing considerations

- Preserve/adapt existing UITest identifiers (`playFreedoom1`, `playTab`/
  `libraryTab`, `addPWADMenu`, `importButton`, control-feel IDs).
- Unit coverage for: `lastPlayed` recency ordering across items; effective
  scheme resolution (`override ?? global`); TITLEPIC decode + palette fallback +
  generated-art fallback; loose-file adoption reflecting into the Library view.
- iOS 26 TabView caveat still applies: tab-bar buttons never receive
  accessibility identifiers — assert panes via `otherElements`, switch via
  button labels.
