# Revyl test definitions

Two device-level tests that run against pull-request preview builds, covering
long-press → **Details** → the detail sheet.

**This file exists because the YAML cannot keep its own documentation.**
`revyl test create --from-file` "copies to `.revyl/tests/` and pushes", and
`revyl test pull` overwrites local — so any round trip through the backend
re-serialises a definition and writes it back. Comments do not survive that.
The rationale therefore lives here, in a file the CLI never touches, and the
YAML headers are deliberately short pointers back to it. Do not move this
content into the YAML; it will be silently deleted the first time anyone syncs,
in a diff that looks like routine CLI churn.

## Why these two tests exist at all

`.github/workflows/ui-tests.yml` runs `WaddleUITests` on `push: main` only.
Between 2026-07-29 and 2026-08-16, eighty-four pull requests merged without it
running once. One of them — PR #144 — replaced the whole app shell, and the
regression it carried, *long-press to Details never opening the detail sheet*,
merged, shipped to TestFlight, and was found weeks later by accident. Two
XCTest cases had been red on `main` the entire time with no red check anywhere.

Revyl's PR review runs on pull requests, so this is the cheapest place to put a
**pre-merge** signal on the one flow already shipped broken once.

### A failure here is a legitimate outcome

These two mirror XCTest cases that were long recorded as red at HEAD, so a
failure was the anticipated result rather than a reason to soften the steps.
That is no longer the state of the world, and the change is in the app's
favour: `PlayTabTests/testBaseGameDetailControlsOverridePersists` passes on
`main`, and the `PresetEditTests` case the other mirrored no longer exists at
all. The tension this section used to flag -- issue #169's lazy-`Form` defect
looking fixed while the learnings file still called both tests red -- resolved
on 2026-09-20 in favour of "fixed": both predecessor learnings were retired for
`docs/learnings/ui-test-failures-need-a-main-baseline.md`, which deliberately
names no tests.

So a failure here is now a **signal, not an expectation**. Fix the app, or
record the failure. Still do not soften the assertions to make them pass, and
still get a `main` baseline before attributing one to your own diff --
`WaddleUITests` runs on no pull request, so `main` can be red for weeks without
a red check anywhere.

## The files

### `shelf-details-sheet.yaml` — base game

Mirrors `WaddleUITests/PlayTabTests/testBaseGameDetailControlsOverridePersists`.
Shelf visible (which doubles as a check that `GameData/` reached the bundle) →
long-press Freedoom Phase 1 → **Details** → **the sheet actually opened**, which
is the shipped regression → set Controls ▸ Layout to Modern → dismiss →
long-press → Details again → Layout still Modern.

### `shelf-preset-details-edit.yaml` — preset

Mirrored `WaddleUITests/PresetEditTests/testEditFromDetailPageOpensEditor`,
which no longer exists -- `App/UITests/` has no `PresetEditTests.swift` as of
2026-09-20. That makes this definition the ONLY coverage of the preset path,
rather than a duplicate of it.
Create a preset from bundled Freedoom Phase 1 via Manage ▸ New Preset → long-press
▸ Details → sheet opened → tap **Edit** in the Contents section → the
**Edit Preset** editor appears.

**Why this cannot be one test.** `PlayableDetailView` hides the whole
Mods/Patches/Compat/Edit group when `game.isBaseGame`, so `detailEditButton`
cannot exist on a base game. The two paths need different fixtures.

This path also exercises a race the base-game path cannot: **Edit** sets
`pendingEditGame`, which `ShelfView` promotes in the sheet's `onDismiss` rather
than presenting the editor in the transaction that dismisses the sheet. The
same-transaction dismiss-then-present bug was already fixed once on the create
path (`cfaed69`). A regression here does not crash — it silently does nothing.

## Traps the instructions steer around

- **Two different "Details" affordances.** `app.buttons["Details"]` matches both
  the long-press context-menu item (no identifier) and the confirmation dialog
  raised by a *short tap* when the game has a resumable save
  (`detailsAction`). The XCTests cannot tell them apart. The instructions force
  a genuine one-second hold — a quick tap on a save-less game goes straight to
  `.launchNewGame`, and once the engine is up the screen is an SDL/Metal surface
  with no accessibility tree.
- **The tile may not be a tile.** Once a game has a resumable save,
  `Shelf.gridItems` drops it from the grid and it appears only as the Continue
  hero, carrying the same context menu. XCTest never sees this because it
  launches with `WADDLE_RESET_STORE=1`; a Revyl device has no such reset, so the
  steps accept either presentation.
- **The sheet is a lazy `Form`.** Rows below the fold are *absent from the
  accessibility hierarchy*, not merely off-screen — which reads exactly like a
  sheet that never presented
  (`docs/learnings/lazy-form-hides-rows-from-uitests.md`). The steps scroll
  rather than assume.
- **Preset naming.** `PresetName.suggested` seeds a preset's name with its base
  game's name verbatim, so a preset left at its default would be called
  "Freedoom Phase 1" and be indistinguishable from the base game on the shelf.
  Renaming it is what makes the later steps unambiguous.
- **No import step, ever.** Freedoom Phase 1 and Phase 2 are bundled, and a test
  device has no files to import.

## Identifiers behind the visible labels

The instructions name visible labels, because the context menu where this flow
lives carries no identifiers. The corresponding ids, for anyone cross-reading
the XCTest suites: `playFreedoom1`, `continueHero`, `detailPlayButton` /
`detailContinueButton`, `detailSchemePicker` (label "Layout", section
"Controls"), `detailEditButton` ("Edit", section "Contents"), `manageButton`,
`newLoadoutButton` ("New Preset"), `createPresetBase-Freedoom Phase 1`,
`loadoutNameField`, `saveLoadoutButton`.

## Wiring them in

These run on pull requests only once `pr_review.workflow_ids` in
`.revyl/config.yaml` names a workflow UUID. See the comment at that field.
Creating it pushes these definitions — at which point the headers below go.

### `menu-state-across-sessions.yaml` — engine relaunch, menu tables

The engine runs in-process: `WoofIOS_Run` calls `D_DoomMain` once per play
session, and the process lives on between sessions. Woof! was written for one
`D_DoomMain` per process, so its file-scope statics assume a process exit ends
their lifetime. `Engine/WOOF_UPSTREAM.md` ("Task 10") lists the ones already
caught. This definition covers the menu tables in `Engine/woof/src/mn_menu.c`:
`M_Init` edits `MainMenu`, `MainDef`, `EpiDef` and the Read This! menus in
place according to `gamemode`, and every *commercial* session (Freedoom Phase
2 is one) applies the edits again on top of the last session's. Measured
2026-09-19: the second Phase 2 session of a launch has no Quit Game entry, and
a Phase 1 session after two Phase 2 sessions has lost Read This!, Quit Game
and two of its four episodes.

Pushed to Revyl on 2026-09-20 as `a82389c1-e0e8-4e5c-8934-539eb1cf7a00`;
the `_meta.remote_id` line in the YAML is that link, and `build.name:
development` is what binds the test to the app -- a push without it is refused
with "a test must be associated with an app", and `revyl test create --app`
does not substitute for it.

Three things about how it is written:

- **The engine ends each session by itself, and the test never navigates
  Doom's menu.** The org launch variable `WADDLE_AUTOQUIT_SECONDS=120` is
  attached to this test (`revyl test launch-var list menu-state-across-sessions`),
  and the Debug build's `EngineSession` seam quits the engine that many
  seconds after it starts. The first two device runs (2026-09-20) tried the
  real quit path instead and never left session 1: the agent could open the
  menu with the overlay's menu button every time, but neither stick swipes
  nor the USE button did anything on the farm's iPhone 17 Pro Max, and taps on
  the menu entries themselves are swallowed by the overlay. The same USE tap
  opens the episode screen in the simulator, so that is an open observation
  about the device, not a known defect. Until it is understood, the only
  overlay control this test relies on is the menu button. It never uses
  `kill_app`/`open_app` either: the defect exists only while one process keeps
  running, and a relaunch would reset every static and pass vacuously.
- **It is judged from screenshots.** The engine surface has no accessibility
  tree, so the validations describe what the Doom menu must show (entry names,
  count, position) rather than elements to query.
- **Its XCTest counterpart is the assertion.** `WaddleUITests/
  MenuStateAcrossSessionsTests` runs four sessions in the simulator with the
  same autoquit seam, also opens the episode screen (which needs USE, so the
  device test leaves it out) and captures the menus as attachments; the issue that
  tracks the fix asks for a debug telemetry seam so that test can assert on the
  table values rather than pixels. This definition exists because Revyl runs on
  pull requests and the XCTest suite does not.
