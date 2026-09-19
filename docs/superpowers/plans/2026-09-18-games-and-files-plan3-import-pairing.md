# Games and Files — Plan 3: import pairing and outcomes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A PWAD that carries maps becomes a shelf tile the moment it is imported, paired to a base of its family; add-ons import as attachable files; the import banner says which of the three happened; an unpaired game says so when launched — spec §3.5 and §4.1, plus a one-time sweep so map sets imported before this build get their tiles too.

**Architecture:** Pairing is a pure rule (`Pairing.chooseBase`) over the installed IWADs and their base games, called from `LibraryService.registerImported` when a map set arrives; it runs once and is never revisited (spec §4.1). `ImportOutcome` gains three categorized lists the banner reads. A flagged launch step, `adoptOrphanMapSets`, runs after the seeder so pre-existing map sets used by no game get a game. The shelf's launch-failure copy distinguishes "no base" from "missing file".

**Tech Stack:** Swift 6, SwiftUI, SwiftData, XCTest. xcodegen project.

**Spec:** `docs/superpowers/specs/2026-09-16-games-and-files-design.md` §3.5, §4.1, §4.2 — §8 item 3. Plan 4 (schema drop) follows.

## Global Constraints

- Conventional commits, no attribution; PR. Branch `tylervick/games-and-files-plan3` **from `tylervick/games-and-files-plan2`** (it needs the game page); PR base is that branch until #231 merges, then main.
- Never weaken a test. Never two `xcodebuild` sessions. `mise run generate` after adding Swift files. Test command as in plans 1–2. Signing fallback as in plans 1–2.
- **Pairing rule (spec §4.1):** candidates are installed IWADs whose `gameFamily == the map set's family`; prefer imported (non-bundled) over bundled; among several imported, the one whose base game was most recently played (`Game.lastPlayed`, nil sorts last), then by `displayName`; among bundled only, by `displayName`. `.unknown` family or no candidate → unpaired (`baseID == nil`). Pairing happens at import and in the one-time sweep only; nothing re-pairs later.
- **Naming (spec §4.2):** the new game's name is the file's `displayName`.
- **Banner copy (spec §3.5), verbatim:** games → "Added <names>"; one add-on → "Imported <name> as an add-on. Attach it from any game's page."; several → "Imported <names> as add-ons. Attach them from any game's page."; one unpaired → "No base game found for <name>. Choose one on its page."; several → "No base game found for <names>. Choose one on their pages."; duplicates and failures keep today's wording. Parts joined by " · " as today.
- **Launch copy:** an unpaired game's launch fails with "This game needs a base game. Choose one on its page."; a missing file keeps "A file in this game is missing from the library."
- `WADDLE_RESET_STORE` clears the new flag `didAdoptOrphanMapSets` too.

---

## File structure

**Create**
- `App/Sources/Models/Pairing.swift` — `Pairing.chooseBase`.
- `App/Tests/PairingTests.swift`.

**Modify**
- `App/Sources/Library/LibraryService.swift` — `pairBase(forFamily:)`, `registerImported` creates a game for a map set, `adoptOrphanMapSets(defaults:)`, `didAdoptOrphanMapSetsKey`.
- `App/Sources/Library/ImportService.swift` — `ImportOutcome.games/addOns/unpaired`, categorization after registration and repair.
- `App/Sources/Library/ImportNotices.swift` — banner parts.
- `App/Sources/Library/GameLauncher.swift` — `LaunchFailure.message(for:)`.
- `App/Sources/UI/ShelfView.swift` — uses it.
- `App/Sources/WaddleApp.swift` — launch order + reset seam.
- Tests: `GameServiceTests`, `ImportServiceTests`, `ImportNoticesTests`, `GameLauncherTests`, `ShelfTests` (comment), `GameMigrationTests` (sweep).
- Docs: spec §5 (sweep) and §3.5 (plural copy); README one sentence.

---

### Task 1: `Pairing` rule, map sets become games at import, orphan sweep

**Files:**
- Create: `App/Sources/Models/Pairing.swift`, `App/Tests/PairingTests.swift`
- Modify: `App/Sources/Library/LibraryService.swift`, `App/Sources/WaddleApp.swift`
- Test: `App/Tests/GameServiceTests.swift`, `App/Tests/GameMigrationTests.swift`, `App/Tests/ShelfTests.swift`

**Interfaces:**
- Produces: `enum Pairing { static func chooseBase(forFamily family: GameFamily, among candidates: [Pairing.Candidate]) -> WADFile? }` with `struct Candidate { let file: WADFile; let lastPlayed: Date? }`.
- `LibraryService`: `func pairBase(forFamily family: GameFamily) throws -> WADFile?`; `registerImported` inserts `Game(name: wad.displayName, baseID: pairBase(...)?.id, fileIDs: [wad.id])` when `wad.role == .mapSet`; `func adoptOrphanMapSets(defaults: UserDefaults = .standard) throws` (flag `didAdoptOrphanMapSetsKey = "didAdoptOrphanMapSets"`): for every non-bundled map set used by no game, create a paired game; runs once.
- `WaddleApp`: order `reconcile → migrateToGames → seed → adoptOrphanMapSets`; reset seam clears the new key.

- [ ] **Step 1: Failing tests**

Create `App/Tests/PairingTests.swift`:

```swift
import XCTest
@testable import Waddle

/// Spec §4.1: which installed IWAD a new map set pairs with.
final class PairingTests: XCTestCase {
    private func iwad(_ name: String, family: GameFamily, bundled: Bool = false) -> WADFile {
        WADFile(filename: name, displayName: (name as NSString).deletingPathExtension,
                kindRaw: WADKind.iwad.rawValue, sha1: name, gameFamilyRaw: family.rawValue,
                isBundled: bundled, hasMaps: true)
    }

    func testPrefersAnImportedIWADOverBundledFreedoom() {
        let freedoom = iwad("freedoom2.wad", family: .doom2, bundled: true)
        let doom2 = iwad("doom2.wad", family: .doom2)
        let chosen = Pairing.chooseBase(forFamily: .doom2, among: [
            .init(file: freedoom, lastPlayed: Date()), .init(file: doom2, lastPlayed: nil),
        ])
        XCTAssertEqual(chosen?.id, doom2.id, "imported wins even when never played")
    }

    func testAmongImportedTheMostRecentlyPlayedWins() {
        let a = iwad("a.wad", family: .doom2), b = iwad("b.wad", family: .doom2), c = iwad("c.wad", family: .doom2)
        let chosen = Pairing.chooseBase(forFamily: .doom2, among: [
            .init(file: a, lastPlayed: Date(timeIntervalSince1970: 100)),
            .init(file: b, lastPlayed: Date(timeIntervalSince1970: 300)),
            .init(file: c, lastPlayed: nil),
        ])
        XCTAssertEqual(chosen?.id, b.id)
    }

    func testNeverPlayedImportedTieBreaksByName() {
        let z = iwad("zeta.wad", family: .doom1), a = iwad("alpha.wad", family: .doom1)
        let chosen = Pairing.chooseBase(forFamily: .doom1, among: [.init(file: z, lastPlayed: nil), .init(file: a, lastPlayed: nil)])
        XCTAssertEqual(chosen?.id, a.id)
    }

    func testFamilyMustMatch() {
        let doom1 = iwad("doom.wad", family: .doom1)
        XCTAssertNil(Pairing.chooseBase(forFamily: .doom2, among: [.init(file: doom1, lastPlayed: Date())]))
    }

    func testUnknownFamilyNeverPairs() {
        let any = iwad("doom2.wad", family: .doom2)
        XCTAssertNil(Pairing.chooseBase(forFamily: .unknown, among: [.init(file: any, lastPlayed: nil)]))
    }

    func testBundledIsTheFallback() {
        let freedoom = iwad("freedoom1.wad", family: .doom1, bundled: true)
        XCTAssertEqual(Pairing.chooseBase(forFamily: .doom1, among: [.init(file: freedoom, lastPlayed: nil)])?.id, freedoom.id)
    }
}
```

Append to `App/Tests/GameServiceTests.swift`:

```swift
    // MARK: Import pairing (spec §3.5, §4.1)

    func testImportingAMapSetCreatesAGamePairedToItsFamilysBase() throws {
        try service.seedBundledContentIfNeeded()               // freedoom1 (doom1), freedoom2 (doom2)
        let map = try service.registerImported(filename: "sunlust.wad", sha1: "s",
                                               kind: WADKind.pwad.rawValue, family: GameFamily.doom2.rawValue,
                                               hasMaps: true)
        let game = try XCTUnwrap(try service.gamesUsing(fileID: map.id).first)
        XCTAssertEqual(game.name, "sunlust")
        XCTAssertEqual(game.fileIDs, [map.id])
        XCTAssertFalse(game.isBaseGame)
        let freedoom2 = try XCTUnwrap(try service.allWADs().first { $0.filename == "freedoom2.wad" })
        XCTAssertEqual(game.baseID, freedoom2.id, "doom2-family map set pairs with the doom2-family base")
        XCTAssertTrue(try service.shelfGames().contains { $0.id == game.id }, "it is a tile")
    }

    func testImportingAMapSetPrefersAnImportedBaseAndIsNeverRePaired() throws {
        try service.seedBundledContentIfNeeded()
        let map = try service.registerImported(filename: "sunlust.wad", sha1: "s",
                                               kind: WADKind.pwad.rawValue, family: GameFamily.doom2.rawValue,
                                               hasMaps: true)
        let pairedToFreedoom = try XCTUnwrap(try service.gamesUsing(fileID: map.id).first).baseID
        // Now the real thing arrives. The existing game stays where it is (spec §4.1)…
        let doom2 = try service.registerImported(filename: "doom2.wad", sha1: "d",
                                                 kind: WADKind.iwad.rawValue, family: GameFamily.doom2.rawValue, hasMaps: true)
        XCTAssertEqual(try service.gamesUsing(fileID: map.id).first?.baseID, pairedToFreedoom, "no silent re-pairing")
        // …but a map set imported from now on prefers it.
        let later = try service.registerImported(filename: "valiant.wad", sha1: "v",
                                                 kind: WADKind.pwad.rawValue, family: GameFamily.doom2.rawValue, hasMaps: true)
        XCTAssertEqual(try service.gamesUsing(fileID: later.id).first?.baseID, doom2.id)
    }

    func testImportingAMapSetOfUnknownFamilyCreatesAnUnpairedGame() throws {
        try service.seedBundledContentIfNeeded()
        let map = try service.registerImported(filename: "weird.wad", sha1: "w",
                                               kind: WADKind.pwad.rawValue, family: GameFamily.unknown.rawValue,
                                               hasMaps: true)
        let game = try XCTUnwrap(try service.gamesUsing(fileID: map.id).first)
        XCTAssertNil(game.baseID)
        XCTAssertTrue(try service.shelfGames().contains { $0.id == game.id }, "unpaired games are still tiles (badge + page)")
    }

    func testImportingAnAddOnOrPatchCreatesNoGame() throws {
        try service.seedBundledContentIfNeeded()
        _ = try service.registerImported(filename: "smooth.wad", sha1: "a", kind: WADKind.pwad.rawValue,
                                         family: GameFamily.doom2.rawValue, hasMaps: false)
        _ = try service.registerImported(filename: "fix.deh", sha1: "p", kind: WADKind.deh.rawValue,
                                         family: GameFamily.unknown.rawValue)
        XCTAssertEqual(try service.games().count, 2, "only the two bundled base games")
    }

    // MARK: Orphan map-set sweep (spec §5 amendment)

    func testAdoptOrphanMapSetsGivesPreExistingMapSetsAGameOnce() throws {
        try service.seedBundledContentIfNeeded()
        // A map set that arrived before pairing existed: a row with maps and no game.
        let orphan = WADFile(filename: "old.wad", displayName: "old", kindRaw: WADKind.pwad.rawValue,
                             sha1: "o", gameFamilyRaw: GameFamily.doom1.rawValue, hasMaps: true)
        context.insert(orphan)
        // A map set already inside a game must not get a second tile.
        let owned = WADFile(filename: "owned.wad", displayName: "owned", kindRaw: WADKind.pwad.rawValue,
                            sha1: "w", gameFamilyRaw: GameFamily.doom1.rawValue, hasMaps: true)
        context.insert(owned)
        let freedoom1 = try XCTUnwrap(try service.allWADs().first { $0.filename == "freedoom1.wad" })
        _ = try service.createGame(name: "Mine", baseID: freedoom1.id, fileIDs: [owned.id])
        try context.save()
        let defaults = UserDefaults(suiteName: "adopt-\(UUID().uuidString)")!

        try service.adoptOrphanMapSets(defaults: defaults)

        let adopted = try XCTUnwrap(try service.gamesUsing(fileID: orphan.id).first)
        XCTAssertEqual(adopted.name, "old")
        XCTAssertEqual(adopted.baseID, freedoom1.id)
        XCTAssertEqual(try service.gamesUsing(fileID: owned.id).count, 1, "an owned map set is left alone")
        XCTAssertTrue(defaults.bool(forKey: LibraryService.didAdoptOrphanMapSetsKey))

        // Second run is a no-op even if the player deletes the adopted game.
        try service.deleteGame(adopted)
        try service.adoptOrphanMapSets(defaults: defaults)
        XCTAssertTrue(try service.gamesUsing(fileID: orphan.id).isEmpty, "the sweep runs once; a deleted game stays deleted")
    }
```

In `App/Tests/ShelfTests.swift`, `testAnImportedModEndsFactoryStateThoughItNeverReachesTheShelf`: the registered PWAD has no maps, so it is an add-on. Rename to `testAnImportedAddOnEndsFactoryStateThoughItNeverReachesTheShelf` and change the assertion message to `"an add-on is not playable on its own and never reaches the shelf"`. Add beside it:

```swift
    func testAnImportedMapSetReachesTheShelfAsAGame() throws {
        try service.seedBundledContentIfNeeded()
        _ = try service.registerImported(filename: "sunlust.wad", sha1: "s",
                                         kind: WADKind.pwad.rawValue, family: "doom2", hasMaps: true)
        XCTAssertTrue(try service.shelfGames().contains { $0.name == "sunlust" && !$0.isBaseGame })
        XCTAssertFalse(try service.isFactoryState())
    }
```

- [ ] **Step 2: Run to verify failure** — `mise run generate`; `PairingTests`, `GameServiceTests`, `ShelfTests`. Expected: `cannot find 'Pairing'`, `has no member 'adoptOrphanMapSets'`, and the two new import tests failing (no game created).

- [ ] **Step 3: Implement**

Create `App/Sources/Models/Pairing.swift`:

```swift
import Foundation

/// Which installed IWAD a newly imported map set loads under (spec §4.1).
/// Pure so the preference order is a test, not a comment.
enum Pairing {
    struct Candidate {
        let file: WADFile
        /// The IWAD's own base game's `lastPlayed`.
        let lastPlayed: Date?
    }

    /// Same family only; an imported IWAD beats bundled Freedoom; among several
    /// imported, the most recently played, then by title. `.unknown` never
    /// pairs. Runs once at import and is never revisited.
    static func chooseBase(forFamily family: GameFamily, among candidates: [Candidate]) -> WADFile? {
        guard family != .unknown else { return nil }
        let matching = candidates.filter { $0.file.gameFamily == family }
        let imported = matching.filter { !$0.file.isBundled }
        let pool = imported.isEmpty ? matching : imported
        return pool.sorted { lhs, rhs in
            switch (lhs.lastPlayed, rhs.lastPlayed) {
            case let (l?, r?) where l != r: return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs.file.displayName.localizedStandardCompare(rhs.file.displayName) == .orderedAscending
            }
        }.first?.file
    }
}
```

In `LibraryService.swift`:

(a) `static let didAdoptOrphanMapSetsKey = "didAdoptOrphanMapSets"` beside the other keys.

(b) After `registerImported`'s `context.insert(wad)`, replace the IWAD-only block with:

```swift
        switch wad.role {
        case .base:
            context.insert(Game.baseGame(for: wad))
        case .mapSet:
            // A map set is a game the moment it arrives, paired once (spec §3.5, §4.1).
            let base = try pairBase(forFamily: wad.gameFamily)
            context.insert(Game(name: wad.displayName, baseID: base?.id, fileIDs: [wad.id]))
        case .addOn:
            break
        }
```

(c) Add:

```swift
    /// The IWAD a new map set of `family` pairs with — see `Pairing.chooseBase`.
    func pairBase(forFamily family: GameFamily) throws -> WADFile? {
        let candidates = try baseGames().map { iwad in
            Pairing.Candidate(file: iwad, lastPlayed: try game(id: iwad.id)?.lastPlayed)
        }
        return Pairing.chooseBase(forFamily: family, among: candidates)
    }

    /// One-time sweep (spec §5, amended for plan 3): map sets imported before
    /// pairing existed have a row but no tile. Each non-bundled map set used by
    /// no game gets a paired game, exactly as if it had just been imported.
    /// Runs after the seeder so bundled bases are available to pair with, and
    /// once only — a game the player later deletes is not resurrected.
    func adoptOrphanMapSets(defaults: UserDefaults = .standard) throws {
        guard !defaults.bool(forKey: Self.didAdoptOrphanMapSetsKey) else { return }
        for wad in try allWADs() where wad.role == .mapSet && !wad.isBundled {
            guard try gamesUsing(fileID: wad.id).isEmpty else { continue }
            let base = try pairBase(forFamily: wad.gameFamily)
            context.insert(Game(name: wad.displayName, baseID: base?.id, fileIDs: [wad.id]))
        }
        try context.save()
        defaults.set(true, forKey: Self.didAdoptOrphanMapSetsKey)
    }
```

In `WaddleApp.swift`: after `try library.seedBundledContentIfNeeded()` add `try library.adoptOrphanMapSets()` with a comment ("after the seeder, so bundled bases exist to pair with"); in the reset block add `UserDefaults.standard.removeObject(forKey: LibraryService.didAdoptOrphanMapSetsKey)`.

- [ ] **Step 4: Run** — `PairingTests`, `GameServiceTests`, `ShelfTests`, `GameMigrationTests`, `ImportServiceTests` (the last two to catch fallout: an import test that counted games may now see one more). Fix only what the new behaviour legitimately changes, and say so.

- [ ] **Step 5: Commit** — `feat(library): a map set becomes a paired game at import; sweep pre-existing ones once`

---

### Task 2: Import outcomes and the banner

**Files:**
- Modify: `App/Sources/Library/ImportService.swift`, `App/Sources/Library/ImportNotices.swift`
- Test: `App/Tests/ImportServiceTests.swift`, `App/Tests/ImportNoticesTests.swift`

**Interfaces:**
- `ImportOutcome` gains `var games: [String] = []`, `var addOns: [String] = []`, `var unpaired: [String] = []`; `merge` appends all three. `imported` keeps every successfully imported/restored name (existing tests rely on it).
- `ImportNotices.summary(of:quarantines:)` emits, in order: games, add-ons, unpaired, then a generic "Imported <names>" only for imported names not in any category (restored files), then duplicates, then failures.

- [ ] **Step 1: Failing tests**

Append to `App/Tests/ImportNoticesTests.swift`:

```swift
    func testGamesAddOnsAndUnpairedEachGetTheirSentence() {
        var outcome = ImportOutcome()
        outcome.imported = ["Sunlust", "smoothdoom", "weird"]
        outcome.games = ["Sunlust"]
        outcome.addOns = ["smoothdoom"]
        outcome.unpaired = ["weird"]
        XCTAssertEqual(ImportNotices.summary(of: outcome),
                       "Added Sunlust · Imported smoothdoom as an add-on. Attach it from any game's page. · No base game found for weird. Choose one on its page.")
    }

    func testPluralAddOnsAndUnpaired() {
        var outcome = ImportOutcome()
        outcome.imported = ["a", "b", "c", "d"]
        outcome.addOns = ["a", "b"]
        outcome.unpaired = ["c", "d"]
        XCTAssertEqual(ImportNotices.summary(of: outcome),
                       "Imported a, b as add-ons. Attach them from any game's page. · No base game found for c, d. Choose one on their pages.")
    }

    func testRestoredFileKeepsTheGenericImportedLine() {
        var outcome = ImportOutcome()
        outcome.imported = ["Sunlust", "restored"]
        outcome.games = ["Sunlust"]
        XCTAssertEqual(ImportNotices.summary(of: outcome), "Added Sunlust · Imported restored")
    }

    func testMergeAppendsTheNewCategories() {
        var a = ImportOutcome(); a.games = ["x"]; a.addOns = ["y"]
        var b = ImportOutcome(); b.unpaired = ["z"]; b.addOns = ["w"]
        a.merge(b)
        XCTAssertEqual(a.games, ["x"]); XCTAssertEqual(a.addOns, ["y", "w"]); XCTAssertEqual(a.unpaired, ["z"])
    }
```

In `App/Tests/ImportServiceTests.swift` add (using the file's `write(_:_:)` fixture and `importer.importFiles(at:)`; `library.seedBundledContentIfNeeded()` first so a doom2 base exists):

```swift
    func testImportCategorizesGamesAddOnsAndUnpaired() throws {
        try library.seedBundledContentIfNeeded()
        let mapSet = try write("sunlust.wad", makeWAD(magic: "PWAD", lumps: ["MAP01", "THINGS"]))   // doom2 family
        let addOn = try write("smooth.wad", makeWAD(magic: "PWAD", lumps: ["TITLEPIC"]))
        let weird = try write("weird.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))                // also doom2 — paired
        let outcome = importer.importFiles(at: [mapSet, addOn, weird])
        XCTAssertEqual(Set(outcome.games), ["sunlust", "weird"])
        XCTAssertEqual(outcome.addOns, ["smooth"])
        XCTAssertTrue(outcome.unpaired.isEmpty)
        XCTAssertEqual(Set(outcome.imported), ["sunlust", "smooth", "weird"], "imported still lists everything")
    }

    func testImportReportsAnUnpairedMapSetWhenNoBaseOfItsFamilyExists() throws {
        // No seed: no bases at all.
        let mapSet = try write("orphan.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let outcome = importer.importFiles(at: [mapSet])
        XCTAssertEqual(outcome.unpaired, ["orphan"])
        XCTAssertTrue(outcome.games.isEmpty)
    }

    func testImportReportsAnIWADAsAGame() throws {
        let iwad = try write("mygame.wad", makeWAD(magic: "IWAD", lumps: ["E1M1", "THINGS"]))
        let outcome = importer.importFiles(at: [iwad])
        XCTAssertEqual(outcome.games, ["mygame"])
    }
```
(If the file's `write` helper has a different name/signature, adapt the call; the assertions are the contract.)

- [ ] **Step 2: Run to verify failure** — `ImportNoticesTests`, `ImportServiceTests`. Expected: `has no member 'games'`.

- [ ] **Step 3: Implement**

`ImportService.swift`:
- `ImportOutcome`: add the three arrays; in `merge`, `games += other.games; addOns += other.addOns; unpaired += other.unpaired`.
- Add a private helper on `ImportService`:

```swift
    /// Which of spec §3.5's three outcomes a freshly registered file is.
    private func categorize(_ wad: WADFile, as name: String, into outcome: inout ImportOutcome) {
        switch wad.role {
        case .base:
            outcome.games.append(name)
        case .mapSet:
            let game = (try? library.gamesUsing(fileID: wad.id))?.first
            if game?.baseID == nil { outcome.unpaired.append(name) } else { outcome.games.append(name) }
        case .addOn:
            outcome.addOns.append(name)
        }
    }
```
- In both `storeAndRegister` and `storeAndRegisterAsync`, capture the return of `registerImported` (`let wad = try library.registerImported(...)`) and call `categorize(wad, as: (stored.filename as NSString).deletingPathExtension, into: &outcome)` right after the existing `outcome.imported.append(...)`. The repair branches stay uncategorized (they keep the generic line).

`ImportNotices.summary`:

```swift
    nonisolated static func summary(of outcome: ImportOutcome, quarantines: Bool = false) -> String? {
        var parts: [String] = []
        if !outcome.games.isEmpty {
            parts.append("Added \(outcome.games.joined(separator: ", "))")
        }
        if !outcome.addOns.isEmpty {
            let names = outcome.addOns.joined(separator: ", ")
            parts.append(outcome.addOns.count == 1
                ? "Imported \(names) as an add-on. Attach it from any game's page."
                : "Imported \(names) as add-ons. Attach them from any game's page.")
        }
        if !outcome.unpaired.isEmpty {
            let names = outcome.unpaired.joined(separator: ", ")
            parts.append(outcome.unpaired.count == 1
                ? "No base game found for \(names). Choose one on its page."
                : "No base game found for \(names). Choose one on their pages.")
        }
        let categorized = Set(outcome.games + outcome.addOns + outcome.unpaired)
        let plain = outcome.imported.filter { !categorized.contains($0) }
        if !plain.isEmpty {
            parts.append("Imported \(plain.joined(separator: ", "))")
        }
        if !outcome.duplicates.isEmpty {
            parts.append("\(outcome.duplicates.count) already in library")
        }
        if !outcome.rejected.isEmpty {
            let suffix = quarantines ? " (moved to Import Failed)" : ""
            parts.append("\(outcome.rejected.count) failed\(suffix)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
```

- [ ] **Step 4: Run** — both classes green; existing `testImportOnly` ("Imported Sunlust") still passes because an uncategorized outcome keeps the generic line.

- [ ] **Step 5: Commit** — `feat(import): say whether a file became a game, an add-on, or needs a base`

---

### Task 3: Launch copy, docs, full suite, PR

**Files:**
- Modify: `App/Sources/Library/GameLauncher.swift`, `App/Sources/UI/ShelfView.swift`, `App/Tests/GameLauncherTests.swift`, spec, README

- [ ] **Step 1: Failing test** — in `GameLauncherTests`:

```swift
    func testLaunchFailureCopyDistinguishesNoBaseFromMissingFile() {
        XCTAssertEqual(LaunchFailure.message(for: LaunchArgumentsError.missingBase),
                       "This game needs a base game. Choose one on its page.")
        XCTAssertEqual(LaunchFailure.message(for: GameLaunchError.missingWAD(UUID())),
                       "A file in this game is missing from the library.")
        XCTAssertEqual(LaunchFailure.message(for: LaunchArgumentsError.missingWAD(UUID())),
                       "A file in this game is missing from the library.")
    }
```

- [ ] **Step 2: Implement** — in `GameLauncher.swift`:

```swift
/// The sentence the shelf shows when a launch cannot even build its argv.
enum LaunchFailure {
    static func message(for error: Error) -> String {
        if case LaunchArgumentsError.missingBase = error {
            return "This game needs a base game. Choose one on its page."
        }
        return "A file in this game is missing from the library."
    }
}
```
In `ShelfView.play`'s `catch`, replace the literal with `let message = LaunchFailure.message(for: error)`.

- [ ] **Step 3: Docs** — spec §5: add a paragraph "Plan 3 adds a second flagged launch step, `adoptOrphanMapSets`, after the seeder: every non-bundled map set no game loads gets a paired game once, so files imported before pairing existed become tiles." Spec §3.5: add the plural forms of the two sentences. README (the import paragraph): one sentence — "A WAD with maps becomes a game on the shelf as soon as it is imported, paired to a base game of its family; patches and map-less WADs import as add-ons you attach from a game's page."

- [ ] **Step 4: Full suite + UI sanity** — `Scripts/check-engine-fresh.sh`; full `-only-testing:WaddleTests`; then `-only-testing:WaddleUITests/GamePageTests -only-testing:WaddleUITests/PlayTabTests -only-testing:WaddleUITests/EngineSmokeTests`.

- [ ] **Step 5: Commit + PR** — `feat(ui): name the missing-base launch failure; document pairing`; push (HTTPS fallback); `gh pr create --base tylervick/games-and-files-plan2` (retarget to main after #231 merges).

---

## Self-review

**Spec coverage (§8 item 3):** §3.5 three outcomes + banner → Task 2. §4.1 pairing rule, once-only → Task 1 (`Pairing`, `pairBase`, the never-re-paired test). §4.2 naming → Task 1 (`displayName`). Unpaired badge/page/pill → already in plan 2; unpaired launch copy → Task 3. Sweep for pre-existing map sets → Task 1 + spec amendment in Task 3.

**Placeholder scan:** Task 2's ImportServiceTests helper name is hedged with one sentence; otherwise none.

**Type consistency:** `Pairing.Candidate(file:lastPlayed:)` used identically in `PairingTests` and `pairBase`; `ImportOutcome.games/addOns/unpaired` in service, notices and tests; `LaunchFailure.message(for:)` in view and test; `didAdoptOrphanMapSetsKey` in service, app and test.
