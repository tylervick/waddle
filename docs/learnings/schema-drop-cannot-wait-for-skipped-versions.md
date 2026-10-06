# A schema drop after a one-time migration cannot wait for every device to have run it

`LibraryService.migrateToGames` reads `Loadout` and three `WADFile` fields
exactly once, on the first launch of the build that introduced `Game`. The
natural next step — ship a follow-up PR that drops the now-unused table and
fields — cannot be timed to be safe for every user, because App Store users
skip versions. A device can jump from a pre-`Game` build straight to
whichever build is live when it next updates; if that build already contains
the drop, the migration that was supposed to run first never gets the chance,
because the schema it reads is already gone.

The only lever available is release timing, not code: ship the migration
alone for at least one release, then land the drop. Plan 4 shipped the drop
anyway, accepting the window it can't close — a device updating straight from
a pre-`Game` build to this one loses its presets and its base games'
hidden/last-played/touch-override state, while saves are untouched (their
directories are keyed by ids that survive independently of both tables). A
device that has passed through any build containing plan 1 first loses
nothing. The decision and the loss are recorded in spec §5
(`docs/superpowers/specs/2026-09-16-games-and-files-design.md`).

A plan-1–3 device whose Freedoom-loadout reconcile
(`reconcileBundledBaseGameLoadouts`, since removed) never completed — it
retries every launch until the save move it depends on stops failing — had
saves still sitting at `Saves/<loadout id>/`, pending a move to the base
game's directory. Plan 4 removes both the `Loadout` table and the reconcile
step, so nothing ever performs that move on such a device: the files are not
deleted, but nothing will look them up again either.

The drop is one-way. Once a plan-4 build has opened the store, `Loadout` and
the three moved `WADFile` columns are gone from the SQLite file; rolling back
to an earlier build finds no `Loadout` table and no presets — SwiftData does
not restore a dropped table on downgrade. TestFlight testers who install an
older build after this one should expect their presets gone, not merely
hidden.

## How this was checked

Procedure: build the old commit; `simctl uninstall`; install; run one of its
UI tests to create real data (1.1: `PresetCreationTests`; plan 3:
`GamePageTests/testRenameFromThePageUpdatesTheTile`); plant hidden/last-played
(REAL-typed) rows with `sqlite3` and a save file under
`Documents/Saves/<uuid>/`; build the new commit; `simctl install` over it (no
uninstall); launch; inspect `default.store` with `sqlite3` (`.tables`,
`pragma table_info(ZWADFILE)`, `select … from ZGAME`), the prefs plist for
the `did*` flags, and `Documents/Saves`; relaunch once more.

- **Result A** (1.1 `f9665a5` → this branch, 2026-09-18): store opened, no
  crash; `ZLOADOUT` and the three `ZWADFILE` columns gone; both Freedoom base
  games created under their IWAD ids; the saves directory survived; the
  preset, the hidden flag and the last-played date did not (the accepted
  window).
- **Result B** (plan 3 `7f3a1de` → this branch, 2026-09-18): the renamed
  duplicate game, both Freedoom rows, the hidden flag, last-played date,
  touch override and save all preserved; Continue hero rendered; second
  launch clean; `didMigrateToGames`/`didAdoptOrphanMapSets` set.
