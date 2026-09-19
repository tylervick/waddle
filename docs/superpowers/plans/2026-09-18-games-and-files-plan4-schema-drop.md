# Games and Files — Plan 4: drop the `Loadout` tombstone and `WADFile`'s legacy fields

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the `Loadout` model, `WADFile`'s three moved fields (`lastPlayed`, `schemeOverrideRaw`, `isHidden`), and the legacy reconcile that read them — spec §8 item 4 — and record the upgrade window this closes.

**Architecture:** `Loadout.swift` is deleted and the model leaves every `ModelContainer`. `migrateToGames` shrinks to "every IWAD row without a game gets a base game with default flags, and present PWADs get `hasMaps`"; `reconcileBundledBaseGameLoadouts`/`migrateSaves`/the phantom predicate go with the table they read. SwiftData's automatic lightweight migration drops the entity and attributes on first open; a simulator upgrade check from both a pre-Game (1.1) store and a plan-3 store proves the store opens and what survives.

**Tech Stack:** Swift 6, SwiftData, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-16-games-and-files-design.md` §5, §2.4, §8 item 4.

## Global Constraints

- Conventional commits, no attribution; **draft PR** against `main`, titled to say it must not merge until a release containing plans 1–3 has been available on the App Store. Branch `tylervick/games-and-files-plan4` from `main` (7f3a1de).
- **Accepted data-loss window (owner decision 2026-09-18):** a device updating from a pre-Game build (1.1 or earlier) straight to a build containing this change loses its presets, and its base games' hidden flag, last-played date and per-game touch override. Save files are untouched (their directories are keyed by ids that survive). A device updating from any build containing plan 1 loses nothing. This is written into spec §5 and a learning.
- Never weaken a test: every removed test is a test of the removed table or fields; successors named in Task 1.
- Never two `xcodebuild` sessions; `mise run generate` after deleting a Swift file; signing fallback as in plans 1–3.

---

### Task 1: The drop

**Files:**
- Delete: `App/Sources/Models/Loadout.swift`
- Modify: `App/Sources/Models/WADFile.swift`, `App/Sources/Library/LibraryService.swift`, `App/Sources/WaddleApp.swift`, `App/Sources/UI/ShelfPreviews.swift`, `App/Sources/Models/Game.swift` (doc comment), every `App/Tests/*.swift` container line, `App/Tests/LibraryServiceTests.swift`, `App/Tests/GameMigrationTests.swift`
- Create: `docs/learnings/schema-drop-cannot-wait-for-skipped-versions.md` + `docs/learnings/INDEX.md` line
- Modify: spec §5, §2.4

**Interfaces:**
- `LibraryService` loses `didReconcileBundledBaseGameLoadoutsKey`, `isPhantomBundledLoadout`, `reconcileBundledBaseGameLoadouts(defaults:)`, `migrateSaves`. `migrateToGames(defaults:)` keeps its name, flag and signature.
- `WADFile.init` loses nothing positional (the three fields were never init parameters); the three stored properties go.
- `WaddleApp` launch order becomes `migrateToGames → seed → adoptOrphanMapSets`; the reset seam no longer deletes `Loadout` or clears the reconcile key.

- [ ] **Step 1: Tests first**

`App/Tests/GameMigrationTests.swift`:
- Delete `legacyLoadout(...)`; simplify `legacyIWAD(_:displayName:bundled:)` to drop the `hidden`/`scheme`/`played` parameters and their assignments.
- Delete (with successors): `testLoadoutBecomesAGameWithTheSameIdAndOrderedFiles` (the table is gone; nothing to migrate), `testMigrationLeavesTheLoadoutRowInPlace` (same), `testMigrationSkipsAPhantomLoadoutUntilTheReconcileHasRun`, `testMigrationCompletesOnTheLaunchAfterTheReconcileSucceeds`, `testMigrationAdoptsASurvivingPhantomShapedLoadoutOnceTheReconcileHasRun`, `testMigrationMigratesANonPhantomLoadoutEvenWithTheSeededTitle` (all four concern the reconcile↔migration hand-off, which no longer exists).
- Rewrite `testIWADRowBecomesABaseGameWithTheSameIdAndFields` → `testIWADRowBecomesABaseGameWithTheSameId`: keep `game.id == wad.id`, `baseID == wad.id`, `isBaseGame`, `name`; add `XCTAssertFalse(game.isHidden)`, `XCTAssertNil(game.lastPlayed)`, `XCTAssertNil(game.schemeOverrideRaw)` with the message "legacy flags no longer carry over (plan 4, accepted)".
- Rewrite `testMigrationDoesNotDuplicateAGameThatAlreadyExists`: keep the count assertion; drop the `isHidden` assertion (no legacy field to differ on).
- Rewrite `testUpgradeOrderKeepsABundledGameHiddenAndAddsNoDuplicate` → `testUpgradeOrderMakesOneBaseGamePerBundledRowAndAddsNoDuplicate`: fake an old store by seeding then deleting all games (as today), run `migrateToGames` then `seedBundledContentIfNeeded`, assert exactly two base games, ids equal to the bundled rows' ids, none hidden.
- Keep `testMigrationFillsHasMaps…`, `testMigrationRunsOnce`, `testMigrationIsANoOpOnAFreshStore` unchanged (they don't touch Loadout).

`App/Tests/LibraryServiceTests.swift`: delete `insertLegacyLoadout`, `legacyLoadouts`, the four `testReconcile*` tests, and `testDeleteWADBlockedByALegacyLoadoutIsNotAThing` (successor: `GameServiceTests.testDeleteUnusedPWADRemovesFileAndRow`).

Every test `setUp` and `ShelfPreviews`/`WaddleApp`: `ModelContainer(for: WADFile.self, Game.self, …)`.

```bash
grep -rl 'Loadout.self' App | xargs sed -i '' 's/WADFile.self, Loadout.self, Game.self/WADFile.self, Game.self/'
```

- [ ] **Step 2: Run to verify RED** — `GameMigrationTests`, `LibraryServiceTests`: compile errors on `Loadout` are expected until Step 3.

- [ ] **Step 3: Drop**

```bash
git rm App/Sources/Models/Loadout.swift && mise run generate
```
`WADFile.swift`: remove the three properties and their `self.x = nil` init lines; remove their doc comments.
`LibraryService.swift`: remove the key, the predicate, `reconcileBundledBaseGameLoadouts`, `migrateSaves`; rewrite `migrateToGames`:

```swift
    /// One-time migration onto `Game` (spec §5). Every IWAD row without a game
    /// becomes its base game **under the IWAD's id**, so `Documents/Saves/<id>/`
    /// stays where the pre-`Game` build left it; present PWADs are re-parsed
    /// to fill `hasMaps`. Runs at most once per install.
    ///
    /// Plan 4 dropped the `Loadout` table and `WADFile`'s moved fields, so a
    /// device coming straight from a pre-`Game` build gets base games with
    /// default flags and no migrated presets — the accepted window recorded in
    /// spec §5 and `docs/learnings/schema-drop-cannot-wait-for-skipped-versions.md`.
    func migrateToGames(defaults: UserDefaults = .standard) throws {
        let flagKey = Self.didMigrateToGamesKey
        guard !defaults.bool(forKey: flagKey) else { return }
        for wad in try allWADs() where wad.kindRaw == WADKind.iwad.rawValue {
            guard try game(id: wad.id) == nil else { continue }
            context.insert(Game.baseGame(for: wad))
        }
        for wad in try allWADs() where wad.kindRaw == WADKind.pwad.rawValue {
            guard let data = try? Data(contentsOf: fileURL(for: wad), options: .mappedIfSafe),
                  let parsed = try? WADParser.parse(data) else { continue }
            wad.hasMaps = WADParser.mapFormat(of: parsed.lumpNames) != .none
        }
        try context.save()
        defaults.set(true, forKey: flagKey)
    }
```
`WaddleApp.swift`: drop the `reconcileBundledBaseGameLoadouts()` call and comment, the `context.delete(model: Loadout.self)` line and the reconcile-key removal. `Game.swift` doc comment: "`Loadout`" → "the old preset model". `seedBundledContentIfNeeded`'s doc comment: remove the sentence about the migration carrying flags across.

Sweep: `grep -rn 'Loadout\|loadout' App/Sources App/Tests` prints only historical doc comments you judge worth keeping (reword any that describe live behaviour).

- [ ] **Step 4: Docs**

Spec §5: replace the "**Schema in this release**: additive … **Follow-up PR** …" paragraph with: "**Schema (plan 4, 2026-09-18):** `Loadout` and the three moved `WADFile` fields are dropped. Accepted window: a device updating from a pre-`Game` build directly to a build with this change loses its presets and its base games' hidden/last-played/touch-override state; saves are untouched. Ship only after a release containing plans 1–3 has been available." §2.4: "`Loadout` (after §5's follow-up)" → "`Loadout` (plan 4)". §8 item 4: mark done.

Learning `docs/learnings/schema-drop-cannot-wait-for-skipped-versions.md` (two short paragraphs): a one-time migration that reads a legacy table cannot be followed by a schema drop that is safe for every user, because App Store users skip versions and the drop happens before the migration runs; the only lever is release timing, and the decision (drop anyway, after plans 1–3 ship) plus what is lost. One INDEX line; `Scripts/check-substrate.sh` must pass.

- [ ] **Step 5: Full suite** — `-only-testing:WaddleTests` green.

- [ ] **Step 6: Commit** — `feat(library)!: drop the Loadout tombstone and WADFile's legacy fields` (the `!` marks the breaking upgrade window; body states it).

---

### Task 2: Upgrade checks and the draft PR (controller)

- Old-store check A (pre-Game): build `f9665a5` (1.1 era), install, let its UI test create a preset, plant a hidden flag, install the plan 4 build over it. Expect: the store **opens**, both Freedoom base games exist, the preset is gone, nothing hidden. Screenshot.
- Old-store check B (plan 3 era): build `7f3a1de`, install, duplicate a game via UI test flow (or `GamePageTests`), rename, then install plan 4. Expect: every game, name, hidden flag and save preserved.
- Push; `gh pr create --draft` with title `feat(library)!: drop the Loadout tombstone (plan 4) — DO NOT MERGE before a plans-1–3 release ships`.
