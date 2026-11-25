# An unset preference cannot tell a new install from an old one

The touch scheme was stored only when a player picked one in Settings. An
install whose key was absent played on `TouchControlScheme.defaultScheme`,
read from code at every session start. So the default was not a default for
new players; it was the live setting of every player who never opened
Settings. Changing it in code (issue #534, Classic to Modern) would have
switched all of them on update, without a word.

`UserDefaults` cannot help after the fact: a new install and an old one that
never chose look exactly alike there. The signal has to come from something
an earlier launch left behind, read *before* this launch writes it again:

- `LibraryService.isExistingInstall` asks before `migrateToGames` and
  `seedBundledContentIfNeeded`. Every build since 2026-07-16 seeds the
  bundled Freedoom rows at its first launch, and every build since
  2026-09-17 sets `didMigrateToGames`. Asked after them, every install,
  including a new one, reads as existing.
- `TouchControlScheme.settleStoredScheme` then stores a value on any install
  with none: `previousDefault` (Classic) for an existing one, `defaultScheme`
  for a new one. Once stored, the key is never unset again, so a new
  install's *second* launch (which now has a library) is not mistaken for an
  old one, and a later change of `defaultScheme` moves nobody.

Two rules follow for any setting whose default might change:

1. Store the value at first launch rather than leaving absence to mean "the
   code default". Absence is then only ever "this launch has not run yet".
2. Keep the historical default as its own constant (`previousDefault`), with
   a test that pins it, so a later edit of the default cannot drag it along.

`TouchControlSchemeTests` (the `settleStoredScheme` cases) and
`LibraryServiceTests` (`isExistingInstall`) are the check. The UI-test seam
`WADDLE_RESET_STORE` also clears the scheme key, so a reset launch is a new
install and starts on the default whatever an earlier build left in the
simulator.
