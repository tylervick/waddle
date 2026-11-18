# Weapon-select grid (the predecessor's switcher)

**Date:** 2026-11-17
**Branch:** `tylervick/weapon-select-grid`
**Status:** design, awaiting approval

## Intent

The per-game DOOM-iOS apps this app replaces let a player tap the middle of
the status bar and pick any weapon from a full-screen 3×3 grid. Waddle only
has ◀ ▶ cycle buttons, so reaching the rocket launcher from the pistol is
several presses mid-fight. This brings the old switcher back, faithfully, as
a first version to play with.

Reference implementation: `~/Documents/DOOM-iOS/code/iphone/iphone_loop.c:1177-1337`
(`DrawWeapon`, `DrawWeaponSelect`), `iphone_async.cpp:585-625` and `:696-717`
(touch and ticcmd handling), `hud.c:80,92` (the hotspot).

## Goals

- Tapping the bottom centre of the picture opens a 3×3 weapon grid; lifting a
  finger on an owned weapon switches to it and closes the grid.
- Cells look and behave as the predecessor's did: name, first-person weapon
  sprite, and the same four states (unowned, owned, owned without ammo,
  pressed).
- The pick is exact: choosing "shotgun" gives the shotgun, not whatever the
  `3` key would toggle to.
- Works for any game Woof can run, including DEHACKED-altered weapons.

## Non-goals

- Removing or changing the ◀ ▶ buttons. They stay exactly as they are (many
  tests pin them, and the layout editor already lets a player move them).
- Making the hotspot visible, movable in the layout editor, or switchable off.
- Changing Woof's own carousel strip or its auto-switch-on-empty behaviour.
- A pixel-identical copy of the old backdrop tile and Arial bitmap font.

## Anti-goals

- A grid that reads as stock iOS chrome (system sheet, blur, SF-styled list).
  It should look like part of the game.
- Any path where a touch held when the grid opens leaves the player walking
  or firing (see `docs/learnings/soft-keyboard-keydown-keyup-pairing.md`).

## Constraints

- Engine changes go in `Engine/woof/` as `engine:` commits, kept minimal and
  recorded in `Engine/WOOF_UPSTREAM.md`.
- Gesture recognizers do not fire in SDL's window; use responder-chain
  touches (`docs/learnings/sdl-window-gesture-recognizers.md`).
- Pull requests run only `WaddleTests`, so the behaviour is proven there
  through pure models. A `WaddleUITests` failure needs a `main` baseline
  before it is blamed on this work
  (`docs/learnings/ui-test-failures-need-a-main-baseline.md`). New files need
  `mise run generate`.
- No test is edited or deleted to make this pass.

## Approaches

1. **Native grid in the touch overlay, plus a small engine shim — chosen.**
   A UIKit view inside `TouchOverlayView`, fed by two or three new
   `WoofIOS_` calls. Matches how menu taps, the automap gestures and the
   layout editor are built; geometry and state are pure Swift and testable
   without a simulator session.
2. **Drawn by the engine**, as the predecessor did. Pixel-authentic and
   palette-correct for free, but a much larger engine patch (drawing, text,
   its own hit-testing fed by pointer events) against a patch set we keep
   small.
3. **No new UI**: rely on Woof's carousel and make the status-bar tap a
   "next weapon" press. Cheapest, but it is not the grid and is no faster
   than ◀ ▶.

Tyler chose the faithful grid; building it natively (1 over 2) is Claude's
call, for the reasons above.

## Design

All fractions below are the predecessor's numbers from its 480×320 virtual
screen, applied to the engine's picture rectangle (`WoofIOS_GetPictureRect`)
rather than the window, so letterboxing and the half-open fold are handled
by what already tracks the picture.

### Hotspot

An invisible touch region, centred horizontally on the picture and anchored
to its bottom edge: 1/6 of the picture's width, 1/4 of its height (the old
40×40 spot at (240, 280) with its doubled touch area). It is not a
`TouchOverlayControl` case, so the editor and every `allCases`-driven test
are untouched. It wins over stick/turn/menu routing for touches that begin
inside it. It is inert whenever the grid cannot open (below). It carries an
accessibility identifier and label ("Weapons") so VoiceOver can reach it.

### When the grid can open

Only while a level is being played by a live local player: not while a menu
or prompt is up, not on the automap, not in attract mode or intermission,
not while dead, not while the soft keyboard is up. The same conditions close
an open grid. The engine keeps running while the grid is open; it is not a
pause. (Claude's call; the predecessor only stopped reading controls.)

### Opening

On touch-down in the hotspot. Opening releases everything held: stick, turn,
FIRE and any held button, each with its paired up/zero write. While open,
touches outside the grid cells and the hotspot do nothing, and no gameplay
input is sent.

### Grid

Nine cells, three per row, in engine weapon order: fist, pistol, shotgun /
chaingun, rockets, plasma / BFG, chainsaw, dblshotgun (the predecessor's
labels). Cell *i* is at column `i % 3`, row `i / 3`; column pitch 160/480 of
picture width with a 20/480 left margin and 120/480 cell width; row pitch
88/320 of picture height, cell height 80/320, starting at the picture's top.
The grid therefore covers the top 264/320 and leaves the status bar and the
hotspot uncovered. All nine cells always show.

Each cell:

- a backdrop panel drawn natively in the game's dark palette (Claude's call:
  the old `multi_backdrop.tga` is not copied in);
- the name, centred near the top;
- the weapon's sprite, bottom-centre pinned in the cell at 1.25× its native
  size (scaled with the picture), nearest-neighbour.

States, as the predecessor tinted them:

| State | Panel | Name | Sprite |
| --- | --- | --- | --- |
| Not owned | dark grey | half opacity | black silhouette |
| Owned, has ammo | white/full | full | full colour |
| Owned, cannot fire | red | half opacity | full colour |
| Finger down on an owned cell | mid grey | — | — |

Owned cells are selectable whether or not they have ammo. Selectability
comes only from the engine's *owned* flag. A cell whose sprite cannot be
produced shows the name alone and stays selectable if owned. (Claude's call:
the predecessor's "no sprite, no pick" rule meant "this weapon is not in the
game", which an unowned cell already covers; applied literally here it would
lock out owned weapons in mods with unusual art.)

### Picking and re-tapping

- Only a touch that began inside a cell after the grid opened can pick.
  Lifted inside the same or another owned cell: select the cell it lifted
  in, close the grid. Lifted anywhere else: nothing; the grid stays.
- Fingers that were already down when the grid opened (a resting stick
  thumb, the finger on the hotspot) are released at open and then ignored
  until they lift; they never pick and never light a cell. (Claude's call,
  and a deliberate departure: the predecessor counted any lift, so relaxing
  the movement thumb over the bottom row picked a weapon by accident.
  Sliding from the hotspot to a cell in one gesture is therefore not
  supported in this version.)
- Touch-down on the hotspot while open: close the grid and switch to the
  engine's best weapon with ammo (`P_SwitchWeapon`, the same call the
  predecessor made).

### Engine shim (`woof_ios.h` / `woof_ios.c`, plus a hook in `G_BuildTiccmd`)

Main-thread-only, same contract as the existing touch calls.

- **Weapon state**: one call filling nine entries with *owned* and *can
  fire*, returning false when the grid may not open (no level, dead, demo
  playback). *Can fire* comes from `weaponinfo[]` (`ammo`, `ammopershot`)
  and the player's ammo, not from the old hardcoded 40-cell/2-shell rules.
- **Select weapon *n***: latches a pending weapon that the next
  `G_BuildTiccmd` turns into `BT_CHANGE` ahead of the key-driven choices,
  skipping `AdjustWeaponSelection`, and resets the next-weapon state
  (`G_NextWeaponReset`) as other direct selections do. Not owning the weapon
  is the engine's existing no-op.
- **Select best weapon**: the same latch, resolved with `P_SwitchWeapon`.
  Not routed through the `0` key, so rebinding cannot break it.
- **Weapon sprite**: copies out frame 0 of the sprite used by
  `weaponinfo[n].readystate` as the engine's own cached patch (so a PNG
  sprite arrives already converted to Doom picture format), plus `PLAYPAL`.
  Swift decodes it with the existing `DoomGraphics.decodePicture` /
  `palette`. A weapon with no such frame yields no sprite.

Known limit, accepted: at a vanilla compatibility level the game itself
swaps fist→chainsaw and shotgun→super shotgun when it applies the command
(`p_user.c:471-481`). That is the original rule and the predecessor had it
too; the shim does not fight it.

### App side (`App/Sources/Touch/`)

- A pure geometry type: picture rect in, hotspot rect and nine cell rects
  out, and "which cell is this point in".
- A pure state type: the nine engine entries in, per-cell appearance and
  selectability out; plus the open/closed machine (open, press, release,
  re-tap, forced close) with the outputs it asks for (release held inputs,
  select *n*, select best).
- A view that draws the cells from those two, owned by `TouchOverlayView`,
  which routes touches to it and polls weapon state while open on the
  existing 0.25 s policy timer or faster.
- Sprites are fetched and decoded once per session, lazily on first open.

### Tests

In `WaddleTests`, against the pure types: hotspot and cell rects for a
full-window, a letterboxed and a pillarboxed picture; point-to-cell mapping
including the gaps; each row of the state table; release inside vs outside
a cell; re-tap; forced close on menu/death; opening emits a release for
every held input. Each new test is shown to discriminate by breaking the
code it covers.

One `WaddleUITests` case in `TouchControlsTests`, in the style of the
existing ones: tap the hotspot, tap an owned cell, and assert through a
debug counter on the shim that exactly one select reached the engine. It
proves the overlay's touch routing and the shim call end to end; it does
not run on pull requests, so it is dispatched on the branch before merge.
Manual steps go in `docs/manual-testing.md`.

## Left to the builder

- Names and signatures of the new shim calls and Swift types.
- Exact colours and font for panel and name, within "looks like the game".
- Whether weapon state is polled or pushed, and at what rate.
- How the grid's cells are exposed to VoiceOver.
- Whether the best-weapon path needs anything beyond `P_SwitchWeapon`
  returning `wp_nochange`.
