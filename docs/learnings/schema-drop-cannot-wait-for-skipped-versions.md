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
