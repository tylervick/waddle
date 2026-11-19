# Weapon-select ring

**Date:** 2026-11-19
**Branch:** `tylervick/weapon-select-ring`
**Status:** direction approved in conversation; details below are Claude's calls unless marked

## Intent

The 3×3 grid (PR #389, `docs/superpowers/specs/2026-11-17-weapon-select-grid-design.md`)
reproduced the predecessor faithfully and, on TestFlight, turned out not to be
the interaction Tyler wanted. What he wants is the current official Doom iOS
app's selector: a half-ring of weapons that fans out above the middle of the
status bar. Tap the bottom middle to toggle it, or press there, slide up, and
lift over the weapon you want.

## Goals

- **Tyler's:** a half-ring selector; tap bottom-middle toggles it; press,
  slide and release over a wedge picks that weapon in one gesture.
- **Tyler's:** seven slots, as in the official app: fist/chainsaw and
  shotgun/super shotgun each share one. A shared slot gives the better weapon
  owned; picking the slot again swaps to the other.
- **Tyler's:** the ring is the default; the grid stays, behind a setting.
- Drawn in Waddle's own style with the game's sprites. The official app's
  stone artwork is not copied.

## Non-goals

- Changing the grid's behaviour, its tests, or the engine's select latch.
- Keeping movement or firing live while the ring is open.
- Per-game selector style (one global setting).

## What exists and is reused unchanged

`WoofIOS_GetWeaponSelectState`, `WoofIOS_SelectWeapon`, `WoofIOS_CopyWeaponSprite`,
`WoofIOS_CopyPlaypal`; `TouchGamepad.weaponSlots()/selectWeapon(_:)/weaponSprites()`;
the `weaponSelectHotspot` view and its accessibility exposure rule (its
frame and hit test depend on the style: the grid's rectangle,
`WeaponSelectGeometry.hotspot`, or the ring's disc, below); the "may open"
conditions; release-held-inputs-on-open and
buttons-disabled-while-open in `TouchOverlayView`; the 0.25 s poll that closes
on menu/automap/death.

## Design

### Setting

`WeaponSelectorStyle: String, CaseIterable` with cases `ring` (default) and
`grid`; `userDefaultsKey = "weaponSelectorStyle"`; `current(defaults:)` with a
DEBUG-only `WADDLE_WEAPON_SELECTOR` environment override, in the shape of
`TouchControlScheme`. A "Weapon Selector" picker (Ring / Grid, identifier
`weaponSelectorPicker`) sits directly under "Touch Controls" in
`PlayerSettingsView`. The overlay reads the style once, when it is installed.

### Engine

One addition: `int WoofIOS_GetSelectedWeapon(void)` — the console player's
`pendingweapon` if one is pending, else `readyweapon`; `-1` under the same
gate as `WoofIOS_GetWeaponSelectState`. The shared slots need it to know
which partner is up. Recorded in `Engine/WOOF_UPSTREAM.md`.

### Slots

| Slot | Weapons (engine numbers) |
| --- | --- |
| 0 | fist (0) / chainsaw (7) |
| 1 | pistol (1) |
| 2 | shotgun (2) / super shotgun (8) |
| 3 | chaingun (3) |
| 4 | rockets (4) |
| 5 | plasma (5) |
| 6 | BFG (6) |

A pure resolver: given the nine owned/can-fire entries and the selected
weapon, each slot yields the weapon a pick would give, or none.

- Single-weapon slot: that weapon if owned.
- Shared slot, one owned: that one.
- Shared slot, both owned: the preferred one (chainsaw, super shotgun),
  unless the preferred one is the selected weapon — then the other.

A slot is selectable when it resolves to a weapon. It shows that weapon's
sprite and "can fire" state. A slot that resolves to none shows the first
weapon's silhouette.

### Geometry (fractions of the engine's picture rectangle `P`)

- Centre: `(P.midX, P.maxY − 32/200 · P.height)` — on the top edge of the
  status bar.
- Outer radius `R = min(0.24 · P.width, 0.55 · 168/200 · P.height)`; inner
  radius `r = 0.40 · R`.
- Seven equal wedges across the upper half-circle, slot 0 at the left
  horizon, slot 6 at the right.
- Two hit bands, both above the centre line and split into the same seven
  angles:
  - **Drawn (strict)**, for touch-downs: distance from the centre greater
    than `r` and at most `R` plus 2 points of slack. A touch-down while the
    ring is open starts tracking only here.
  - **Generous**, for a finger already tracked (its moves and its lift):
    distance between `0.75 · r` and `1.35 · R`, so a slide can overshoot
    the drawing and still pick.
- The hotspot (ring style only) is a disc: every point within `r` of the
  centre, clipped to `P`. It covers the ring's hole and the status-bar strip
  under the centre, and does not overlap the drawn band. The
  `weaponSelectHotspot` view's frame is the disc's bounding box clipped to
  `P`; its centre is in the disc and in no wedge. The grid style keeps its
  own rectangle (`WeaponSelectGeometry.hotspot`) unchanged.

### Gestures

Closed, and the ring may open:

- **Touch-down in the hotspot** opens the ring and releases held inputs, as
  the grid does. Unlike the grid, the opening finger is tracked.
- That finger **moves**: the wedge under it (generous band) highlights.
- It **lifts without ever leaving the hotspot** (a tap): the ring stays open.
  This wins where the generous band reaches into the hotspot disc
  (`0.75 · r` to `r`): a tap never picks.
- Otherwise, it **lifts over a selectable wedge** (generous band): pick it,
  close.
- It **lifts anywhere else**: close, no pick.

Open:

- **Touch-down on a drawn wedge** (strict band): that finger is tracked;
  lifting over a selectable wedge (generous band) picks and closes; lifting
  elsewhere leaves the ring open.
- **Touch-down in the hotspot**: close, no pick. (The grid's re-tap selects
  the best weapon; a toggle that changes weapon would be a surprise here.)
- **Touch-down anywhere else**, including just off the drawing (a button
  past the outer edge, a thumb under the inner edge): close, no pick; the
  touch is consumed.
- Only one finger is tracked at a time. A finger in the same `touchesBegan`
  batch as the one that opens or closes the ring is consumed and can neither
  pick nor steer (same rule the grid has).
- Forced close (menu, automap, death, keyboard) forgets the tracked finger.

### Drawing

Seven wedge panels with a thin gap between them, in the grid's panel palette:
unowned dark with a silhouette, ready, red when owned but unable to fire,
brighter when the tracked finger is over a selectable wedge. The slot holding
the selected weapon carries an accent outline. No blur, no system materials,
no name labels.

Each sprite is drawn upright and nearest-neighbour, at the largest size of
its own aspect ratio that fits inside its wedge's panel: it starts from the
aspect fit to a `0.8 · (R − r)` square centred at the wedge's mid-radius
point and shrinks in 5 % steps until its corners, and three more points
along each edge, are all inside the panel path (a panel is only about
`0.32 · R` across at wedge 3's midpoint, so a wide sprite shrinks rather
than being cut). In the end wedges (0 and 6) the midpoint is only
`0.156 · R` above the centre line, so a sprite whose bottom would fall below
the centre line (less the gap) is first moved up to it. The sprite is also
masked to its panel, as a safety net only.

Wedges are accessibility elements `weaponCell0`…`weaponCell6` (the grid's
identifier scheme, by slot), labelled with the resolved weapon's name, with
the same `.button` / `.notEnabled` traits and values the grid's cells use,
and only while the ring is shown. Each wedge view's frame (its accessibility
frame) is the sprite square centred on the wedge's midpoint, which is on the
drawn wedge; its `accessibilityPath` is the panel in screen coordinates, so
VoiceOver outlines the wedge itself rather than the overlapping squares.
The view and its wedges take no touches; the overlay owns them.

### Tests

Unit (`WaddleTests`): the style's default, persistence and override; the slot
resolver's table including both swap cases; geometry (wedge of a point,
overshoot band, below-centre rejection, a small and a widescreen picture);
every gesture line above as a model test; the view's identifiers, traits and
nil-sprite handling.

UI (`WaddleUITests`, new tests only):

- press on the hotspot, drag to `weaponCell0`, release → the ring closes and
  `ws` is exactly 1;
- with `WADDLE_WEAPON_SELECTOR=grid`, the grid still opens and picks.

`testWeaponGridPicksAnOwnedWeapon` is not edited. It names no style, so it
now runs against the ring, and its steps hold there: a tap opens and leaves
the ring open, a tap on slot 2 (shotgun, not owned at warp start) picks
nothing, a tap on slot 0 picks the fist.

## Left to the builder

Type and file names beyond those above; colours within the grid's palette;
how the overlay shares code between the two styles; whether the highlight
animates.
