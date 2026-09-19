# Games and Files — launcher reframing

**Date:** 2026-09-16
**Status:** Approved design, pending implementation plan
**Supersedes:** the Play/Library rework's two-level "playable items vs. raw
files" model (`2026-07-23-play-library-rework-design.md`, §"Design
philosophy") and the Manage door of the launcher UX spec
(`2026-08-13-launcher-ux-design.md`, §3). Everything else in the launcher
UX spec — the shelf, hero, welcome card, dark shell, Freedoom decisions —
stands.

## 1. Problem

The launcher has two stored playable things and one adapter over them.

- `WADFile` is a file *and*, when its kind is IWAD, a game: it carries
  `lastPlayed`, `schemeOverrideRaw`, `isHidden` and a saves directory that
  mean nothing for a PWAD or DEH row.
- `Loadout` (shown as "Preset") carries the same three fields again plus a
  file list, and is the only way to play a mod.
- `PlayableItem` switches between the two so the shelf can pretend they are
  one kind of thing.

That duplication leaks into the UI as three pains, all confirmed on
2026-09-16:

1. **Manage is a grab-bag.** One screen holds files grouped by kind, a
   Presets list, a Hidden-from-Shelf list, Import, and New Preset. It has no
   single job.
2. **Presets are heavy and second-class.** Playing a mod means constructing
   and naming a thing, in a different place from the base game it came from,
   through a Save/Cancel form reached by a Details → Edit two-step (with the
   dismiss/present transaction workaround that two-step needs).
3. **Saves are hard to reason about.** They hang off an IWAD row or a Loadout
   row; deleting a preset forks into keep/delete-saves; the player can only
   see them deep in Details.

## 2. The model

Two nouns.

**A Game is what you play.** One base IWAD, zero or more other files in load
order, a compat level, a touch-layout override, a hidden flag, a last-played
date, and its saves. Every IWAD is a game with no other files. Every imported
PWAD that carries maps becomes a game, paired to a base of its family.

**A File is what is on disk.** Bundled or imported, with a size and a
derived role. Files show up in two places only: a storage screen under
Settings, and the Add picker on a game's page.

"Preset", "Loadout", "Manage" and "Base game" as a tile subtitle leave the
UI. The shelf shows games. Nothing else is a tile.

### 2.1 Roles

Derived from the file, never stored as a separate kind:

| File | Role | Becomes |
|---|---|---|
| IWAD | base | a game (its own, `isBaseGame`) |
| PWAD with maps (`mapFormat != .none`) | map set | a game, paired to a base |
| PWAD without maps | add-on | nothing; attachable to any game |
| DEH / BEX | patch (an add-on) | nothing; attachable to any game |

### 2.2 `Game`

```swift
@Model final class Game {
    @Attribute(.unique) var id: UUID   // see §5: migration reuses old ids
    var name: String
    var baseID: UUID?                  // an IWAD WADFile; nil = unpaired
    var fileIDs: [UUID]                // every non-base file, in load order
    var complevel: String?
    var schemeOverrideRaw: String?
    var isHidden: Bool
    var lastPlayed: Date?
    var createdAt: Date
    var isBaseGame: Bool               // the IWAD's own game: hide-only, base locked
}
```

One ordered `fileIDs` list, not separate mod and patch lists: load order is
one sequence in the engine, and each entry's role comes from its `WADFile`.
Argument building emits `-file` for the WAD entries in order and `-deh` for
the patch entries in order, exactly as `LoadoutArguments.build` does today.
The saves key is `game.id`.

### 2.3 `WADFile`

Becomes purely a file. Gains `hasMaps: Bool`, set at import from
`WADParser.mapFormat`. Loses `lastPlayed`, `schemeOverrideRaw` and
`isHidden` to `Game` (retained in the schema for one release, see §5).

### 2.4 Removed

`Loadout` (after §5's follow-up), `PlayableItem`, `PresetName`,
`PresetCreationFlow`, `LoadoutEditorView`, and `LibraryView` (Manage).

## 3. Screens

Four screens plus About, down from seven. Wireframes from the design
session live in `.superpowers/brainstorm/` (gitignored) and are summarized
here.

### 3.1 Shelf

Unchanged in structure: hero zone, one adaptive grid, welcome card,
`Shelf`'s ordering and tap rules. Three changes:

- Toolbar is **Add** (opens the importer) and the gear. The Manage door is
  gone. The welcome card's Add Your Games and the ghost tile call the same
  importer.
- An unpaired game's tile carries a small **Needs a base game** badge.
  Tapping it opens the game page instead of launching.
- Long-press gains **Hide from Shelf** on a base game and **Delete** on any
  other game, alongside Continue / New Game / Details.

### 3.2 Game page

One screen for every tile, replacing `PlayableDetailView`,
`LoadoutEditorView` and `PresetCreationFlow`. **Edits apply in place**: no
Edit mode, no Save/Cancel. The page is pushed into the shelf's navigation stack, not presented as a sheet. Sections, top to bottom:

1. Title art, name (tap to rename) — a Rename alert with a text field, then **Continue** and **New Game** when a
   resumable save exists, else **Play** alone. Same rule as today
   (`PlayableLauncher.continuableSlot`).
2. **Base game** — a picker over installed IWADs. Locked on a base game's
   own page.
3. **Maps & Add-ons** — one reorderable list in load order. Each row shows
   the filename and its role (Map set / Add-on / Patch — the map count was dropped at implementation: it needs a column nothing else reads). Remove with the row's minus button (the page keeps edit mode on so load order can be dragged; that also replaces swipe-to-delete on this list and on Saves — an implementation amendment). An **Add…** row opens a picker of every non-base file not already
   in the list, grouped by role.
4. **Compatibility** — the existing complevel picker.
5. **Touch layout** — the existing per-item scheme override.
6. **Saves** — the existing list, minus-button delete, see item 3.
7. **Duplicate**, then **Delete Game** (or **Hide from Shelf** on a base
   game).

**Change-with-saves confirmation.** When a game has at least one save and
the player changes its base or its file list, a confirmation offers
**Duplicate Instead** (default), **Change Anyway**, and **Cancel**.
Duplicate Instead copies the game with the pending change applied, named
"<name> copy", and leaves the original and its saves alone. Rename, compat
and touch layout never trigger it.

### 3.3 Settings sheet

Keeps touch layout, control feel, debug toggle and About. Gains a
**Library** group with two pushed rows:

- **Files** — §3.4.
- **Hidden games** — today's Restore list.

### 3.4 Files

Storage only. Grouped by role (Base games / Map sets / Add-ons). Each row:
filename, size, Bundled/Imported/Missing, and a "Used by …" line naming the
games that load it ("Not used by any game" otherwise; a map set with no base
shows a *no base* pill). Row actions: Show in Files where the file is in the
container, and Delete — blocked with the list of games while any game uses
it, exactly today's "File in use" alert. Bundled files cannot be deleted.
**No import button**: the shelf's Add is the one door.

### 3.5 Import

Machinery unchanged (multi-select, zip, hash dedupe, off-main hashing). Each
imported file lands as one of three outcomes, reported in the existing
bottom banner alongside today's duplicate/rejection lines:

- a new game tile on the shelf;
- an add-on — "Imported smoothdoom.wad as an add-on. Attach it from any
  game's page.";
- an unpaired game — "No base game found for sunlust.wad. Choose one on its
  page."

## 4. Rules

### 4.1 Pairing

A new map set pairs with an installed IWAD of its family
(`WADParser.gameFamily`: MAPxx → doom2, ExMy → doom1), preferring an
imported IWAD over bundled Freedoom, and among several imported ones the
most recently played. No match → unpaired. Pairing happens **once at import
and is never revisited automatically**: importing doom2.wad later leaves
Sunlust on Freedoom until the player changes its base. Silent re-pairing
would move a game out from under its saves.

### 4.2 Naming

An auto-created game takes its file's `displayName` (already the catalog
title for recognized IWADs). Duplicate names "<name> copy". Rename is on the
game page.

### 4.3 Saves

Every game owns one saves directory, `Documents/Saves/<game.id>/`. Continue
and the hero read it as today. Deleting a game deletes it. Hiding keeps it.

### 4.4 Deletion

- **Delete Game** confirms "Delete <name> and its N saves?" and, when no
  other game uses the game's map-set files, offers **Also Delete
  <file>**. Add-on files are never deleted with a game.
- **Base games** are hidden, not deleted. Deleting the IWAD *file* happens in
  Files: it deletes the IWAD's own base game and that game's saves, and is
  blocked while any **other** game uses the IWAD. (Without this carve-out an
  imported IWAD could never be deleted, since its own base game always uses
  it.)
- **Delete a file** (Files screen) is blocked while any game uses it.
  Bundled files are never deletable (`LibraryError.wadIsBundled` stays).

### 4.5 Seeder

`seedBundledContentIfNeeded` creates each bundled Freedoom `WADFile` if
missing and its base game **only when no Game with that `baseID` and
`isBaseGame` exists, hidden or not**. A hidden game still exists, so it is
never resurrected — the guarantee the current `isHidden` design relies on.

## 5. Migration

A one-time launch step behind a `UserDefaults` flag, following the pattern
`reconcileBundledBaseGameLoadouts` already uses — **not** a SwiftData
versioned schema. A custom SwiftData stage can read the old rows or write
the new ones but not both in one context, so it would need a scratch file
anyway; the launch step needs neither.

Steps, in order:

1. For each IWAD `WADFile`: create `Game(id: wad.id, name: wad.displayName,
   baseID: wad.id, fileIDs: [], schemeOverrideRaw: wad.schemeOverrideRaw,
   isHidden: wad.isHidden, lastPlayed: wad.lastPlayed, isBaseGame: true)`.
2. For each `Loadout`: create `Game(id: loadout.id, name, baseID: iwadID,
   fileIDs: pwadIDs + dehIDs, complevel, schemeOverrideRaw, isHidden,
   lastPlayed, createdAt, isBaseGame: false)`.
3. For each PWAD `WADFile` whose file is present: parse the directory and
   set `hasMaps`. Missing files keep `hasMaps = false` and their status
   stays Missing; a game referencing one launches as today (the engine
   reports the missing file).
4. Set the flag. On a fresh install the step is a no-op.

**Ids are reused on purpose**: the saves key was `WADFile.id` for base games
and `Loadout.id` for presets, and it is `game.id` now, so no directory under
`Documents/Saves/` moves and a player updating mid-campaign gets their
Continue hero back untouched.

**Schema in this release**: additive. `Game` is added; the `Loadout` table
and `WADFile`'s three moved fields stay, written by nothing and read only by
the migration. **Follow-up PR** after a TestFlight build has migrated real
data: drop them (a lightweight SwiftData change).

## 6. Testing

Hermetic unit tests, all under `WaddleTests`:

- **Roles**: IWAD → base; PWAD+maps → map set; PWAD−maps and DEH → add-on.
- **Pairing**: family match; imported-over-bundled; most-recent among
  several; unknown family and no installed base → unpaired; never revisited
  on later import.
- **Migration**: one Game per IWAD row and per Loadout with the old id;
  every moved field copied exactly; `hasMaps` filled from present files;
  missing files tolerated; flag makes it run once; no-op on fresh store.
- **Seeder**: does not create a second base game for a hidden Freedoom game.
- **Arguments**: `-file`/`-deh` ordering from one `fileIDs` list matches
  today's `LoadoutArgumentsTests` expectations; saves path is
  `Saves/<game.id>`.
- **Deletion**: game delete removes saves; file offer only when unused
  elsewhere; add-ons never deleted; in-use file delete blocked with names.
- **Shelf**: `ShelfTests` re-pointed at `Game`; unpaired tap resolves to
  open-page, not launch.
- **Change-with-saves**: fires for base/file-list changes only; Duplicate
  Instead leaves the original untouched.

UI tests keep launching through the existing tile identifiers. `manageScreen`,
`managePreset-*`, `newLoadoutButton`, `createPresetBase-*`, `saveLoadoutButton`
and the preset editor's identifiers go away; `importButton` moves to the
shelf. Pinned user-facing strings ("Manage", "Preset", "New Preset") change —
see `docs/learnings/ui-tests-pin-user-facing-strings.md`.

## 7. Out of scope

- Automatic re-pairing when a better base is imported.
- Guessing which family a map-less add-on belongs to.
- Any change inside the engine session.
- Dropping `Loadout` and the moved `WADFile` fields (the follow-up PR, §5).
- Per-game control *feel* (still deferred from the 2026-07-23 spec).

## 8. Decomposition

Landing order, each its own PR:

1. `Game` model + migration + seeder rule + `LibraryService` API over Game
   (`shelfItems`, `hiddenItems`, `games(using:)`, pairing, roles). Shelf and
   launcher switch to `Game`; `PlayableItem` deleted. UI otherwise unchanged.
2. Game page replacing Details + editor + creation flow; Manage door
   removed; Add on the shelf; Settings gains Files and Hidden games.
3. Import outcomes (auto-create game / add-on / unpaired) and the banner
   copy; unpaired tile badge.
4. Follow-up after TestFlight: drop `Loadout` and the moved fields.
