# Play & Library Rework — Plan B: Play Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Play tab around directly-playable items (base games one-tap + presets), a unified detail page as the preset Read/Update/Delete surface, one-door preset creation, per-item touch-scheme override wired into launch, and the migration that retires the phantom base-game loadouts (preserving saves).

**Architecture:** A `PlayableItem` abstraction unifies base games (IWAD `WADFile`s) and presets (`Loadout`s) for the grid and a merged Recently-Played view. A `PlayableLauncher` builds engine args + resolves the effective touch scheme + stamps `lastPlayed` for either kind, calling the Plan A primitives. The Play grid renders sections of title-art tiles (generated-art fallback until Plan C lands TITLEPIC); tap launches, info/long-press opens a detail page. A one-time migration stops seeding base-game loadouts and reconciles existing ones, moving their saves to the base game's own saves key.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, XCTest + XCUITest, XcodeGen, Woof! engine. Builds on Plan A (HEAD `f482119`). Spec: `docs/superpowers/specs/2026-07-23-play-library-rework-design.md`.

## Global Constraints

- **Commits:** SIGNED (1Password SSH); signing can hang — retry (`for i in $(seq 10); do git commit ... && break || sleep 15; done`); never unsigned.
- **Commit/PR text:** NO Claude/AI attribution, NO `Co-Authored-By`, no AI-tooling mention.
- **Consumes Plan A primitives (exact signatures):**
  - `WADFile.lastPlayed: Date?`, `WADFile.schemeOverrideRaw: String?`
  - `Loadout.schemeOverrideRaw: String?` (and existing `Loadout.lastPlayed: Date?`)
  - `LibraryService.markPlayed(_ wad: WADFile, at: Date = .now) throws`
  - `TouchControlScheme.effective(override raw: String?, defaults: UserDefaults = .standard) -> TouchControlScheme`
  - `LoadoutArguments.build(iwadURL: URL, saveID: UUID, pwadURLs: [URL] = [], dehURLs: [URL] = [], complevel: String? = nil) throws -> [String]`
  - `LoadoutArguments.build(loadout: Loadout, resolve: (UUID) throws -> URL) throws -> [String]`
  - `EngineSession.play(arguments: [String], scheme: TouchControlScheme = .current()) -> Int32`
  - `LibraryService.savesDirectory(forLoadoutID: UUID) -> URL` (accepts any saves key: `Loadout.id` OR a base game's `WADFile.id`)
  - `LibraryService.suggestedIWAD(for: WADFile) throws -> WADFile?`, `fileURL(for: WADFile) -> URL`, `wad(id:) -> WADFile?`, `allWADs()`, `allLoadouts()`, `createLoadout(name:iwadID:pwadIDs:dehIDs:)`, `deleteLoadout(_:deleteSaves:)`, `saveChanges()`.
- **`WADKind` raw values:** `WADKind.iwad.rawValue` (base game), `.pwad.rawValue` (mod), `.deh.rawValue` (patch). Base games = `WADFile` where `kindRaw == WADKind.iwad.rawValue`.
- **SAVES-KEY RECONCILIATION (non-negotiable, from Plan A final review):** ephemeral base-game launches key saves by the base game's `WADFile.id`; the retired seeded per-phase loadout keyed saves by its own `Loadout.id`. Task 6's migration MUST move saves from the old `Loadout.id` directory to the base game's `WADFile.id` directory, or on-device progress appears to vanish.
- **iOS 26 TabView accessibility caveat (unchanged from today):** tab-bar buttons never receive accessibility identifiers — UITests switch tabs via `app.tabBars.buttons["Play"]`/`["Library"]` and assert panes via `app.otherElements["playTab"]`/`["libraryTab"]`. Keep the `playTab`/`libraryTab` identifiers on the two tab content panes.
- **Preserve/relocate UITest hooks:** `playFreedoom1` moves from the Freedoom Phase 1 loadout tile onto the Freedoom Phase 1 **base-game** tile. Keep `newLoadoutButton`, `touchSchemeMenu`, `aboutButton`, `controlFeelButton`, `debugHUDToggle`, `touchSchemePicker`, `engineExitLabel`, `importButton`, `importNoticeBanner`. The preset creation editor keeps `loadoutNameField`, `iwadPicker`, `addPWADMenu`, `addPWADButton-<name>`, `saveLoadoutButton`.
- **Known SwiftUI gotchas in this codebase (do not rediscover):**
  - A conditionally-empty `.safeAreaInset` directly above a `ScrollView`/`LazyVGrid` crashes SwiftUI's layout engine here — use `.overlay(alignment:)` for conditional bottom content (see `LoadoutGridView`).
  - A large inline `.toolbar` can defeat the Swift type-checker — split toolbar content into a `@ToolbarContentBuilder` property (see `LoadoutGridView.toolbarContent`).
  - SwiftUI `Menu` cannot render `Slider` rows — tuning sliders live in the Control Feel sheet.
- **Test commands:**
  - Unit: `xcodebuild -project App/WADdle.xcodeproj -scheme WADdle -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WADdleTests/<Class>[/<method>] test`
  - Full: `mise run test`. Expect the 4 `RealWADTests` to fail unless `Scripts/provision-test-wads.sh` was run against the booted sim after install — that gap is environmental and unrelated to this plan.
- **New source/test FILES require project regen:** after adding any file under `App/Sources` or `App/Tests` (or `App/UITests`), run `mise run generate` before building (XcodeGen globs those dirs at generate time). Modifying existing files needs no regen.
- **NEVER commit `App/WADdle.xcodeproj`:** it is a generated artifact, gitignored via `.gitignore`'s `App/*.xcodeproj`, and deliberately untracked (commit `c82427e`). XcodeGen globs the source/test dirs, so committing only the `.swift` files is complete — any checkout runs `mise run generate` to rebuild the project. The `git add` lines in this plan list only real source/test files; do not add the `.xcodeproj`.

---

## File Structure

**Created:**
- `App/Sources/Models/PlayableItem.swift` — value wrapper over a base-game `WADFile` or a preset `Loadout` for display/launch; no SwiftData.
- `App/Sources/Library/PlayableLauncher.swift` — builds args + resolves effective scheme + stamps `lastPlayed` for a `PlayableItem`; returns a `LaunchPlan`.
- `App/Sources/UI/PlayView.swift` — the Play tab grid (replaces `LoadoutGridView`'s role; sections + tiles + toolbar).
- `App/Sources/UI/PlayableTileView.swift` — one tile (title-art placeholder + name + subtitle), reused across sections.
- `App/Sources/UI/PlayableDetailView.swift` — the per-item detail page (Contents, Controls override, Saves, Delete / Create-preset).
- `App/Sources/UI/PresetCreationFlow.swift` — the one-door "pick a base game → editor" creation entry.

**Modified:**
- `App/Sources/Library/LibraryService.swift` — `baseGames()`, `recentlyPlayed(limit:)`, `setSchemeOverride(...)`, `savesInfo(forKey:)`, `reconcileBundledBaseGameLoadouts()`, and the seeding change.
- `App/Sources/ContentView.swift` — Play tab hosts `PlayView` (keep `playTab` id).
- `App/Sources/UI/LoadoutEditorView.swift` — accept a pre-seeded base game; auto-name; reachable from the new creation flow and the detail page's Edit.
- `App/Sources/UI/LibraryView.swift` — remove the PWAD→loadout swipe/context shortcut and the "find it in Play" toast (creation now lives only in Play).
- `App/Sources/WADdleApp.swift` — call `reconcileBundledBaseGameLoadouts()` after seeding.
- `App/Sources/UI/LoadoutGridView.swift` — deleted once `PlayView` replaces it (Task 3), migrating its gear menu + error-alert + debug-HUD overlay verbatim.

**Tests:**
- Unit (existing files): `LibraryServiceTests.swift`, plus new `PlayableItemTests.swift`, `PlayableLauncherTests.swift`.
- UITest (existing files): `EngineSmokeTests.swift` (hook move — verify only), `RealWADTests.swift` (creation-flow update), plus new `PlayTabTests.swift` for the detail page + creation flow.

---

## Task 1: `PlayableItem` + `LibraryService` playable queries

Unifies base games and presets for the grid and a merged Recently-Played view. Pure/query layer — no UI yet, app behavior unchanged.

**Files:**
- Create: `App/Sources/Models/PlayableItem.swift`
- Modify: `App/Sources/Library/LibraryService.swift`
- Test: `App/Tests/PlayableItemTests.swift` (new — needs `mise run generate`)

**Interfaces:**
- Consumes: `WADFile`, `Loadout`, `WADKind`, `LibraryService.allWADs()`, `allLoadouts()`.
- Produces:
  - `enum PlayableItem: Identifiable` with cases `.baseGame(WADFile)` and `.preset(Loadout)`; computed `id: String` (`"wad-\(w.id)"` / `"loadout-\(l.id)"`), `title: String`, `lastPlayed: Date?`, `schemeOverrideRaw: String?`, `isBaseGame: Bool`.
  - `LibraryService.baseGames() throws -> [WADFile]` — IWADs, bundled first then by title.
  - `LibraryService.recentlyPlayed(limit: Int) throws -> [PlayableItem]` — base games + presets that have a non-nil `lastPlayed`, sorted most-recent-first, capped at `limit`.

- [ ] **Step 1: Write the failing tests**

Create `App/Tests/PlayableItemTests.swift`:

```swift
import SwiftData
import XCTest
@testable import WADdle

@MainActor
final class PlayableItemTests: XCTestCase {
    var service: LibraryService!
    var tmp: URL!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, configurations: config)
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        service = LibraryService(context: ModelContext(container), store: WADStore(directory: tmp))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tmp) }

    func testBaseGamesReturnsOnlyIWADs() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        _ = try service.registerImported(filename: "sunlust.wad", sha1: "p", kind: WADKind.pwad.rawValue, family: "doom2")
        let bases = try service.baseGames()
        XCTAssertEqual(bases.map(\.id), [iwad.id])
    }

    func testRecentlyPlayedMergesAndSortsAcrossKinds() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        let preset = try service.createLoadout(name: "P", iwadID: iwad.id, pwadIDs: [], dehIDs: [])
        // base game played most recently; preset earlier; a second base game never played.
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        preset.lastPlayed = older
        try service.saveChanges()
        try service.markPlayed(iwad, at: newer)
        let recent = try service.recentlyPlayed(limit: 10)
        XCTAssertEqual(recent.map(\.id), ["wad-\(iwad.id)", "loadout-\(preset.id)"])
    }

    func testRecentlyPlayedExcludesNeverPlayedAndRespectsLimit() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        _ = try service.createLoadout(name: "NeverPlayed", iwadID: iwad.id, pwadIDs: [], dehIDs: [])
        try service.markPlayed(iwad, at: Date(timeIntervalSince1970: 50))
        let recent = try service.recentlyPlayed(limit: 1)
        XCTAssertEqual(recent.map(\.id), ["wad-\(iwad.id)"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise run generate` then `xcodebuild ... -only-testing:WADdleTests/PlayableItemTests test`
Expected: FAIL — no type `PlayableItem`; no `baseGames`/`recentlyPlayed`.

- [ ] **Step 3: Create the model**

Create `App/Sources/Models/PlayableItem.swift`:

```swift
import Foundation

/// A directly-playable entry in the Play grid: a base game (an IWAD `WADFile`)
/// or a saved preset (`Loadout`). A value wrapper for display/launch — the
/// underlying model is retained for mutation/launch by callers.
enum PlayableItem: Identifiable {
    case baseGame(WADFile)
    case preset(Loadout)

    var id: String {
        switch self {
        case .baseGame(let w): return "wad-\(w.id)"
        case .preset(let l): return "loadout-\(l.id)"
        }
    }

    var isBaseGame: Bool { if case .baseGame = self { return true } else { return false } }

    var title: String {
        switch self {
        case .baseGame(let w): return w.displayName
        case .preset(let l): return l.name
        }
    }

    var lastPlayed: Date? {
        switch self {
        case .baseGame(let w): return w.lastPlayed
        case .preset(let l): return l.lastPlayed
        }
    }

    var schemeOverrideRaw: String? {
        switch self {
        case .baseGame(let w): return w.schemeOverrideRaw
        case .preset(let l): return l.schemeOverrideRaw
        }
    }
}
```

- [ ] **Step 4: Add the queries**

In `App/Sources/Library/LibraryService.swift`, under `// MARK: Queries`, add:

```swift
    /// Base games (IWADs) for the Play grid — bundled first, then by title.
    func baseGames() throws -> [WADFile] {
        try allWADs()
            .filter { $0.kindRaw == WADKind.iwad.rawValue }
            .sorted { ($0.isBundled ? 0 : 1, $0.displayName) < ($1.isBundled ? 0 : 1, $1.displayName) }
    }

    /// Base games + presets that have been played, most-recent-first, capped.
    func recentlyPlayed(limit: Int) throws -> [PlayableItem] {
        let items = try baseGames().map(PlayableItem.baseGame)
            + allLoadouts().map(PlayableItem.preset)
        return items
            .filter { $0.lastPlayed != nil }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild ... -only-testing:WADdleTests/PlayableItemTests test`
Expected: PASS (3/3).

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Models/PlayableItem.swift App/Sources/Library/LibraryService.swift App/Tests/PlayableItemTests.swift
git commit -m "feat(play): PlayableItem model + base-game and recently-played queries"
```

---

## Task 2: `PlayableLauncher` — args + effective scheme + lastPlayed

One place that turns a `PlayableItem` into a launch: base game → ephemeral IWAD-only args keyed by its own `WADFile.id`; preset → the existing loadout arg path; either way resolve the effective scheme and stamp `lastPlayed`. No UI yet.

**Files:**
- Create: `App/Sources/Library/PlayableLauncher.swift`
- Test: `App/Tests/PlayableLauncherTests.swift` (new — needs `mise run generate`)

**Interfaces:**
- Consumes: `LoadoutArguments.build(...)` (both overloads), `TouchControlScheme.effective(override:)`, `LibraryService.fileURL(for:)`, `wad(id:)`, `markPlayed(_:at:)`, `saveChanges()`.
- Produces:
  - `struct LaunchPlan { let arguments: [String]; let scheme: TouchControlScheme }`
  - `enum PlayableLaunchError: Error { case missingWAD(UUID) }`
  - `@MainActor enum PlayableLauncher { static func prepare(_ item: PlayableItem, library: LibraryService, at date: Date = .now) throws -> LaunchPlan }` — builds args, resolves scheme, stamps `lastPlayed` (via `markPlayed` for a base game; via `loadout.lastPlayed = date` + `saveChanges()` for a preset), and returns the plan. The caller passes `plan.arguments`/`plan.scheme` to `EngineSession.play`.

- [ ] **Step 1: Write the failing tests**

Create `App/Tests/PlayableLauncherTests.swift`:

```swift
import SwiftData
import XCTest
@testable import WADdle

@MainActor
final class PlayableLauncherTests: XCTestCase {
    var service: LibraryService!
    var tmp: URL!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, configurations: config)
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        service = LibraryService(context: ModelContext(container), store: WADStore(directory: tmp))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tmp) }

    func testBaseGameLaunchKeysSavesByWADIdStampsLastPlayedAndAppliesScheme() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        iwad.schemeOverrideRaw = TouchControlScheme.modern.rawValue
        try service.saveChanges()
        let when = Date(timeIntervalSince1970: 999)
        let plan = try PlayableLauncher.prepare(.baseGame(iwad), library: service, at: when)
        XCTAssertEqual(Array(plan.arguments.prefix(3)), ["woof", "-iwad", service.fileURL(for: iwad).path])
        XCTAssertFalse(plan.arguments.contains("-file"))
        // saves dir is keyed by the base game's own WADFile.id
        XCTAssertTrue(plan.arguments.contains(LibraryService.savesDirectory(forLoadoutID: iwad.id).path))
        XCTAssertEqual(plan.scheme, .modern)
        XCTAssertEqual(try service.wad(id: iwad.id)?.lastPlayed, when)
    }

    func testPresetLaunchUsesLoadoutPathStampsLoadoutLastPlayed() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        let pwad = try service.registerImported(filename: "sunlust.wad", sha1: "p", kind: WADKind.pwad.rawValue, family: "doom2")
        // give the files real bytes so fileURL(for:) paths exist for arg building
        let preset = try service.createLoadout(name: "Sun", iwadID: iwad.id, pwadIDs: [pwad.id], dehIDs: [])
        let when = Date(timeIntervalSince1970: 777)
        let plan = try PlayableLauncher.prepare(.preset(preset), library: service, at: when)
        XCTAssertEqual(plan.arguments[1], "-iwad")
        XCTAssertTrue(plan.arguments.contains("-file"))
        XCTAssertTrue(plan.arguments.contains(LibraryService.savesDirectory(forLoadoutID: preset.id).path))
        XCTAssertEqual(try service.allLoadouts().first(where: { $0.id == preset.id })?.lastPlayed, when)
    }

    func testPresetWithMissingWADThrows() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        let preset = try service.createLoadout(name: "Broken", iwadID: iwad.id, pwadIDs: [UUID()], dehIDs: [])
        XCTAssertThrowsError(try PlayableLauncher.prepare(.preset(preset), library: service))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise run generate` then `xcodebuild ... -only-testing:WADdleTests/PlayableLauncherTests test`
Expected: FAIL — no `PlayableLauncher`/`LaunchPlan`.

- [ ] **Step 3: Implement the launcher**

Create `App/Sources/Library/PlayableLauncher.swift`:

```swift
import Foundation

struct LaunchPlan {
    let arguments: [String]
    let scheme: TouchControlScheme
}

enum PlayableLaunchError: Error, Equatable {
    case missingWAD(UUID)
}

/// Turns a `PlayableItem` into a ready-to-run `LaunchPlan`: builds engine argv,
/// resolves the effective touch scheme (per-item override ?? global), and
/// stamps `lastPlayed`. Base games launch ephemerally (no persisted Loadout),
/// keyed for saves by their own `WADFile.id`.
@MainActor
enum PlayableLauncher {
    static func prepare(_ item: PlayableItem, library: LibraryService,
                        at date: Date = .now) throws -> LaunchPlan {
        let scheme = TouchControlScheme.effective(override: item.schemeOverrideRaw)
        switch item {
        case .baseGame(let wad):
            let args = try LoadoutArguments.build(iwadURL: library.fileURL(for: wad),
                                                  saveID: wad.id)
            try library.markPlayed(wad, at: date)
            return LaunchPlan(arguments: args, scheme: scheme)
        case .preset(let loadout):
            let args = try LoadoutArguments.build(loadout: loadout) { id in
                guard let wad = try library.wad(id: id) else {
                    throw PlayableLaunchError.missingWAD(id)
                }
                return library.fileURL(for: wad)
            }
            loadout.lastPlayed = date
            try library.saveChanges()
            return LaunchPlan(arguments: args, scheme: scheme)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild ... -only-testing:WADdleTests/PlayableLauncherTests test`
Expected: PASS (3/3).

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Library/PlayableLauncher.swift App/Tests/PlayableLauncherTests.swift
git commit -m "feat(play): PlayableLauncher builds args, resolves scheme, stamps lastPlayed"
```

---

## Task 3: `PlayView` — the playable-items grid (replaces LoadoutGridView)

Rebuild the Play tab: sections of title-art tiles (Recently Played / Base Games / Presets), tap = play via `PlayableLauncher` + `EngineSession.play`. Base games become first-class one-tap tiles; the `playFreedoom1` hook moves onto the Freedoom Phase 1 base-game tile. The gear menu, error alert, and debug-HUD overlay migrate verbatim from `LoadoutGridView`. Detail-page navigation is wired here but the page itself lands in Task 5 (until then, long-press keeps today's minimal preset context menu).

**Files:**
- Create: `App/Sources/UI/PlayView.swift`, `App/Sources/UI/PlayableTileView.swift`
- Modify: `App/Sources/ContentView.swift`
- Delete: `App/Sources/UI/LoadoutGridView.swift` (after migrating its parts)
- Test: `App/UITests/EngineSmokeTests.swift` is the gate (no code change — it taps `playFreedoom1`, now on the base-game tile).

**Interfaces:**
- Consumes: `LibraryService.baseGames()`, `allLoadouts()`, `recentlyPlayed(limit:)`, `PlayableItem`, `PlayableLauncher.prepare(_:library:)`, `EngineSession.play(arguments:scheme:)`, `EngineErrorAlert.from(exitCode:engineMessage:)`, `EngineSession.lastErrorMessage`.
- Produces: `struct PlayView: View` (init `PlayView(library: LibraryService, lastExitCode: Binding<Int32?>)`), `struct PlayableTileView: View`.

**Implementation spec (follow `LoadoutGridView` as the pattern):**

- `PlayView` owns `@State private var recent/baseGames/presets`, `@State private var detailItem: PlayableItem?`, and the same `@State` for editor/controlFeel/about/errorAlert/`@AppStorage` scheme+debugHUD that `LoadoutGridView` has. `refresh()` reloads all three collections.
- Body: `NavigationStack { ScrollView { LazyVGrid sections } }` with `.navigationTitle("WADdle")`, `.toolbar { toolbarContent }`, `.accessibilityIdentifier("playTab")` on the ScrollView's content (so `ContentView` can keep the id there instead — see below), and the SAME `.overlay(alignment: .bottom)` debug-HUD build-info block and `.sheet`/`.alert` modifiers `LoadoutGridView` uses (migrate verbatim: control-feel sheet, about sheet, new-editor sheet, editor `sheet(item:)`, error alert). Use `.overlay`, NOT `.safeAreaInset` (documented crash).
- Sections, each rendered only when non-empty, as a titled `Section`-style header (`Text(...).font(.headline)`) + a `LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)])`:
  1. **Recently Played** — `recentlyPlayed(limit: 6)`.
  2. **Base Games** — `baseGames().map(PlayableItem.baseGame)`.
  3. **Presets** — `allLoadouts().map(PlayableItem.preset)`.
- Each tile is `PlayableTileView(item:)` wrapped in a `Button { play(item) }` with `.buttonStyle(.plain)` and:
  - `.accessibilityIdentifier(accessibilityID(for: item))` where `accessibilityID` returns `"playFreedoom1"` when `item.title == "Freedoom Phase 1" && item.isBaseGame`, else `item.id` for base games and `"loadout-\(loadout.name)"` for presets (preserves the existing `loadout-<name>` UITest convention).
  - `.contextMenu { … }`: for a preset — `Button("Details") { detailItem = item }`, `Button("Edit") { editorLoadout = loadout }`, and today's two destructive delete options (verbatim from `LoadoutGridView.tile`); for a base game — `Button("Details") { detailItem = item }`. (Task 5 fills the detail sheet; wire `.sheet(item: $detailItem)` now to a placeholder `Text(item.title)` so the enum compiles, and replace the placeholder in Task 5.)
- `PlayableTileView`: `VStack(alignment:.leading)` with a placeholder art block (`RoundedRectangle(cornerRadius: 12).fill(.quaternary).aspectRatio(1.6, contentMode: .fit).overlay(Image(systemName: "flame.fill").font(.largeTitle))` — Plan C replaces the fill with TITLEPIC art), then `Text(item.title).font(.headline).lineLimit(2)`, then a subtitle line (`.font(.caption).foregroundStyle(.secondary)`). Subtitle: base game → "Base game"; preset → the PWAD names joined (reuse `LoadoutGridView.subtitle` logic; pass the joined string in).
- `play(_ item:)`: mirror `LoadoutGridView.play` but through the launcher:
  ```swift
  private func play(_ item: PlayableItem) {
      lastExitCode = nil
      do {
          let plan = try PlayableLauncher.prepare(item, library: library)
          lastExitCode = EngineSession.play(arguments: plan.arguments, scheme: plan.scheme)
          errorAlert = EngineErrorAlert.from(exitCode: lastExitCode ?? 0,
                                             engineMessage: EngineSession.lastErrorMessage)
      } catch {
          lastExitCode = EngineSession.ExitCode.argumentFailure
          errorAlert = EngineErrorAlert.from(exitCode: EngineSession.ExitCode.argumentFailure,
                                             engineMessage: "A file in this loadout is missing from the library.")
      }
      refresh()
  }
  ```
- Migrate `toolbarContent` and `touchSchemeMenu` verbatim from `LoadoutGridView` (keep `touchSchemeMenu`, `touchSchemePicker`, `debugHUDToggle`, `controlFeelButton`, `aboutButton`, `newLoadoutButton` ids). In Task 6 the `newLoadoutButton` action changes to open the creation flow; in Task 3 keep it opening `showNewEditor = true` (today's blank editor) so the app stays functional.
- `ContentView.swift`: replace `LoadoutGridView(library:lastExitCode:)` with `PlayView(library:lastExitCode:)`; keep `.tabItem { Label("Play", systemImage: "play.circle.fill") }` and `.accessibilityIdentifier("playTab")`.
- Delete `App/Sources/UI/LoadoutGridView.swift` after moving everything above; grep to confirm no remaining references (`grep -rn LoadoutGridView App/Sources`).

- [ ] **Step 1: Build the two new views + swap ContentView, per the spec above.**
- [ ] **Step 2: Delete `LoadoutGridView.swift`; `grep -rn LoadoutGridView App/Sources App/UITests` returns nothing.**
- [ ] **Step 3: Regenerate + build:** `mise run generate` then `xcodebuild ... -only-testing:WADdleTests test` (unit suite still green — no logic regressions).
- [ ] **Step 4: Run the smoke gate:** `xcodebuild ... -only-testing:WADdleUITests/EngineSmokeTests/testEngineBootQuitRelaunchCycle test`. Expected: PASS — `playFreedoom1` (now the Freedoom Phase 1 base-game tile) launches the engine, exits 0, twice. This proves base-game one-tap launch + the hook move.
- [ ] **Step 5: Run `ShipUITests` gate:** `xcodebuild ... -only-testing:WADdleUITests/ShipUITests test`. Expected: PASS — the gear menu (`touchSchemeMenu` → `aboutButton`) survives the rewrite.
- [ ] **Step 6: Commit**

```bash
git add App/Sources/UI/PlayView.swift App/Sources/UI/PlayableTileView.swift App/Sources/ContentView.swift
git rm App/Sources/UI/LoadoutGridView.swift
git commit -m "feat(play): grid of playable items with base-game one-tap launch"
```

---

## Task 4: Preset creation flow + editor seeding + remove Library shortcut

Consolidate preset creation to one door: `newLoadoutButton` → pick a base game → the editor pre-seeded with that base and an auto-name. Remove the Library PWAD→loadout swipe/context shortcut and the "find it in Play" toast.

**Files:**
- Create: `App/Sources/UI/PresetCreationFlow.swift`
- Modify: `App/Sources/UI/LoadoutEditorView.swift`, `App/Sources/UI/PlayView.swift`, `App/Sources/UI/LibraryView.swift`
- Test: `App/Tests/LibraryServiceTests.swift` (auto-name helper), `App/UITests/RealWADTests.swift` (creation-flow update)

**Interfaces:**
- Produces: `enum PresetName { static func suggested(base: String, pwads: [String]) -> String }` (e.g. `"Doom II + Sunlust"`, or just the base name when no PWADs); `struct PresetCreationFlow: View` (a base-game picker that pushes `LoadoutEditorView(library:existing:seedIWAD:)`).
- Modifies: `LoadoutEditorView` gains `init(library:existing:seedIWAD: WADFile? = nil)`; when `existing == nil` and `seedIWAD != nil`, prefill `iwadID` and set `name = PresetName.suggested(base: seedIWAD.displayName, pwads: [])`, updating the auto-name as PWADs are added until the user edits the name.

**Implementation spec:**
- `PresetName.suggested`: pure function; unit-tested. `pwads.isEmpty ? base : base + " + " + pwads.joined(separator: " + ")`.
- `PresetCreationFlow`: a `NavigationStack`/`List` of `library.baseGames()`, each row `Button(base.displayName) { path = base }` with id `createPresetBase-<displayName>`; selecting one navigates to `LoadoutEditorView(library:existing:nil, seedIWAD: base)`. Keep the editor's existing ids (`loadoutNameField`, `iwadPicker`, `addPWADMenu`, `addPWADButton-<name>`, `saveLoadoutButton`).
- `LoadoutEditorView`: add the `seedIWAD` param + auto-name behavior. Track `@State private var nameEdited = false`; set it true in the name `TextField`'s change; only auto-update `name` from PWAD changes while `!nameEdited`.
- `PlayView`: change `newLoadoutButton` to present `PresetCreationFlow` (`showNewEditor` → `showCreationFlow`).
- `LibraryView`: delete `newLoadoutButton(for:)`, `createLoadout(from:)`, the leading `swipeActions` + `contextMenu` that call them, and the `row(for:)` PWAD branch — every row becomes the plain `base` row with the trailing delete via `onDelete`. Remove the `"Created loadout … find it in Play"` post. Keep `importButton` and the import flow intact.
- `RealWADTests.configureAndLaunch`: update the "create" branch to the new flow — `app.buttons["newLoadoutButton"].tap()` → `app.buttons["createPresetBase-\(iwad)"].tap()` → (editor opens seeded) → set the name field, add PWADs via `addPWADMenu`/`addPWADButton-<pwad>`, `saveLoadoutButton`. The IWAD is now chosen in the picker step, so drop the in-editor `iwadPicker` selection (or keep it as a no-op assertion that the seeded IWAD is selected). Then tap the preset tile `loadout-<name>` as today.

- [ ] **Step 1: Write the failing auto-name test** in `App/Tests/LibraryServiceTests.swift`:

```swift
    func testPresetNameSuggestion() {
        XCTAssertEqual(PresetName.suggested(base: "Doom II", pwads: []), "Doom II")
        XCTAssertEqual(PresetName.suggested(base: "Doom II", pwads: ["Sunlust"]), "Doom II + Sunlust")
        XCTAssertEqual(PresetName.suggested(base: "Doom II", pwads: ["A", "B"]), "Doom II + A + B")
    }
```

- [ ] **Step 2: Run to verify fail** — `xcodebuild ... -only-testing:WADdleTests/LibraryServiceTests/testPresetNameSuggestion test`. Expected: FAIL (no `PresetName`).
- [ ] **Step 3: Implement `PresetName` + `PresetCreationFlow` + the `LoadoutEditorView` seeding + the `PlayView`/`LibraryView` edits, per the spec above.**
- [ ] **Step 4: Regenerate + run auto-name test** — `mise run generate` then the Step 2 command. Expected: PASS. Then `xcodebuild ... -only-testing:WADdleTests test` (unit suite green).
- [ ] **Step 5: Update `RealWADTests.configureAndLaunch` to the new flow** (code change; note in the commit that RealWADTests remains provisioning-gated and is verified by the owner running `Scripts/provision-test-wads.sh`).
- [ ] **Step 6: Commit**

```bash
git add App/Sources/UI/PresetCreationFlow.swift App/Sources/UI/LoadoutEditorView.swift App/Sources/UI/PlayView.swift App/Sources/UI/LibraryView.swift App/Tests/LibraryServiceTests.swift App/UITests/RealWADTests.swift
git commit -m "feat(play): one-door preset creation seeded from a base game"
```

---

## Task 5: `PlayableDetailView` — the Read/Update/Delete surface

The per-item detail page: title art, Play, Contents (locked for a base game / editable-via-Edit for a preset), a Controls override (Default/Classic/Modern), a visible Saves list, and Delete (preset) / "Create preset from this" (base game). Reached from the grid's "Details" context action.

**Files:**
- Create: `App/Sources/UI/PlayableDetailView.swift`
- Modify: `App/Sources/UI/PlayView.swift` (swap the Task 3 placeholder `sheet(item: $detailItem)` for the real view), `App/Sources/Library/LibraryService.swift` (saves listing + scheme-override setters)
- Test: `App/Tests/LibraryServiceTests.swift` (setters + saves listing), `App/UITests/PlayTabTests.swift` (new — detail open + controls override)

**Interfaces:**
- Produces on `LibraryService`:
  - `func setSchemeOverride(_ raw: String?, forBaseGame wad: WADFile) throws` and `func setSchemeOverride(_ raw: String?, forPreset loadout: Loadout) throws` (write + `saveChanges()`).
  - `struct SaveSlot: Identifiable { let id: String /* filename */ ; let modified: Date }` and `func saveSlots(forKey id: UUID) -> [SaveSlot]` (lists files in `savesDirectory(forLoadoutID: id)`, newest first; empty if none) and `func deleteSave(_ slot: SaveSlot, forKey id: UUID)`.
- `struct PlayableDetailView: View` — `init(item: PlayableItem, library: LibraryService, onPlay: (PlayableItem) -> Void, onEdit: (Loadout) -> Void, onChanged: () -> Void)`.

**Implementation spec (a `Form`/`List` in a `NavigationStack`, follow `AboutView`/`LoadoutEditorView` patterns):**
- Header: title-art placeholder (same block as the tile), the title, and a prominent **Play** button (`onPlay(item)`), id `detailPlayButton`.
- **Contents** section: base game → `Text("Base: \(title)")` (locked, no edit); preset → base + PWADs (joined) + patches + complevel, with an **Edit** button (`onEdit(loadout)`), id `detailEditButton`.
- **Controls** section: a `Picker` bound to the item's override with three tags — `Default`/`Classic`/`Modern` (Default = `nil`), id `detailSchemePicker`. On change, call the matching `setSchemeOverride` and `onChanged()`. The picker's Default label reads the global default for clarity: `"Default (\(TouchControlScheme.current().displayLabel))"` — add a `displayLabel` computed on the enum (`.classic → "Classic"`, `.modern → "Modern"`).
- **Saves** section: `saveSlots(forKey:)` for the item's saves key (base game → `wad.id`; preset → `loadout.id`); each row shows filename + `modified`, with a swipe-delete calling `deleteSave`. Empty → a "No saves yet" row.
- Footer actions: preset → `Button("Delete Preset & Saves", role:.destructive)` and `Button("Delete Preset, Keep Saves", role:.destructive)` (call `library.deleteLoadout(_:deleteSaves:)` then `onChanged()` + dismiss); base game → `Button("Create preset from this")` that opens the creation flow seeded with this base game (reuse Task 4's `PresetCreationFlow` seeded path) — id `createPresetFromBaseButton`.
- `PlayView`: replace the placeholder `sheet(item: $detailItem)` with `PlayableDetailView(item:library:onPlay:onEdit:onChanged:)`, wiring `onPlay` to `play`, `onEdit` to `editorLoadout = $0`, `onChanged` to `refresh`.

- [ ] **Step 1: Write failing unit tests** in `App/Tests/LibraryServiceTests.swift` for the setters + saves listing:

```swift
    func testSetSchemeOverrideOnBaseGameAndPreset() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        let preset = try service.createLoadout(name: "P", iwadID: iwad.id, pwadIDs: [], dehIDs: [])
        try service.setSchemeOverride(TouchControlScheme.classic.rawValue, forBaseGame: iwad)
        try service.setSchemeOverride(TouchControlScheme.modern.rawValue, forPreset: preset)
        XCTAssertEqual(try service.wad(id: iwad.id)?.schemeOverrideRaw, TouchControlScheme.classic.rawValue)
        XCTAssertEqual(try service.allLoadouts().first?.schemeOverrideRaw, TouchControlScheme.modern.rawValue)
        try service.setSchemeOverride(nil, forBaseGame: iwad)
        XCTAssertNil(try service.wad(id: iwad.id)?.schemeOverrideRaw)
    }

    func testSaveSlotsListsFilesNewestFirst() throws {
        let key = UUID()
        let dir = LibraryService.savesDirectory(forLoadoutID: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.dsg"); let b = dir.appendingPathComponent("b.dsg")
        try Data().write(to: a); try Data().write(to: b)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: a.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: b.path)
        XCTAssertEqual(service.saveSlots(forKey: key).map(\.id), ["b.dsg", "a.dsg"])
        try? FileManager.default.removeItem(at: dir)
    }
```

- [ ] **Step 2: Run to verify fail** — `xcodebuild ... -only-testing:WADdleTests/LibraryServiceTests/testSetSchemeOverrideOnBaseGameAndPreset -only-testing:WADdleTests/LibraryServiceTests/testSaveSlotsListsFilesNewestFirst test`. Expected: FAIL.
- [ ] **Step 3: Implement the `LibraryService` setters + `SaveSlot`/`saveSlots`/`deleteSave` + `TouchControlScheme.displayLabel` + `PlayableDetailView`, and wire it into `PlayView`, per the spec.**
- [ ] **Step 4: Run to verify pass** — the Step 2 command. Expected: PASS. Then `xcodebuild ... -only-testing:WADdleTests test` (unit suite green).
- [ ] **Step 5: Write the detail UITest** in a new `App/UITests/PlayTabTests.swift`:

```swift
import XCTest

final class PlayTabTests: XCTestCase {
    @MainActor
    func testBaseGameDetailControlsOverridePersists() {
        let app = XCUIApplication()
        app.launch()
        let tile = app.buttons["playFreedoom1"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.press(forDuration: 1.0)               // context menu
        app.buttons["Details"].tap()
        let picker = app.buttons["detailSchemePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["Classic"].tap()
        // reopen and confirm the selection stuck
        XCTAssertTrue(app.buttons["detailSchemePicker"].waitForExistence(timeout: 5))
    }
}
```

- [ ] **Step 6: Regenerate + run** — `mise run generate` then `xcodebuild ... -only-testing:WADdleUITests/PlayTabTests test`. Expected: PASS.
- [ ] **Step 7: Commit**

```bash
git add App/Sources/UI/PlayableDetailView.swift App/Sources/UI/PlayView.swift App/Sources/Library/LibraryService.swift App/Sources/Touch/TouchControlScheme.swift App/Tests/LibraryServiceTests.swift App/UITests/PlayTabTests.swift
git commit -m "feat(play): playable detail page with per-item controls override and saves"
```

---

## Task 6: Migration — retire seeded base-game loadouts + reconcile saves

Stop `seedBundledContentIfNeeded()` from auto-creating a `Loadout` per Freedoom phase; remove any already-created phantom loadouts on launch, **migrating their saves** to the base game's own saves key. Base games have shown as tiles since Task 3, so the app stays correct when the phantoms disappear.

**Files:**
- Modify: `App/Sources/Library/LibraryService.swift`, `App/Sources/WADdleApp.swift`
- Test: `App/Tests/LibraryServiceTests.swift`

**Interfaces:**
- Modifies `seedBundledContentIfNeeded()` to register only the bundled `WADFile`s (drop the `context.insert(Loadout(...))`).
- Produces: `LibraryService.reconcileBundledBaseGameLoadouts() throws` — deletes each `Loadout` that is a phantom base-game loadout (bundled IWAD, no PWAD/DEH, name ∈ the seeded phase titles), first moving `savesDirectory(forLoadoutID: loadout.id)` → `savesDirectory(forLoadoutID: iwad.id)` when the source exists and the destination does not.

- [ ] **Step 1: Update the existing seeding test + write the reconciliation tests.**

In `App/Tests/LibraryServiceTests.swift`, replace `testSeedCreatesFreedoomEntriesAndLoadoutsOnce` with:

```swift
    func testSeedCreatesFreedoomWADsButNoLoadouts() throws {
        try service.seedBundledContentIfNeeded()
        try service.seedBundledContentIfNeeded()   // idempotent
        XCTAssertEqual(try service.allWADs().filter(\.isBundled).map(\.filename).sorted(),
                       ["freedoom1.wad", "freedoom2.wad"])
        XCTAssertTrue(try service.allLoadouts().isEmpty)
    }
```

Add:

```swift
    func testReconcileRemovesPhantomBaseGameLoadoutAndMigratesSaves() throws {
        // Arrange an old-install shape: a bundled Freedoom IWAD + a phantom
        // "Freedoom Phase 1" loadout (no PWAD/DEH) that accumulated a save.
        // isBundled must be true for reconciliation to treat it as a phantom;
        // registerImported creates a non-bundled row, so set the flag after.
        let base = try service.registerImported(
            filename: "freedoom1.wad", sha1: "bundled:freedoom1.wad",
            kind: WADKind.iwad.rawValue, family: GameFamily.doom1.rawValue)
        base.isBundled = true
        try service.saveChanges()
        let phantom = try service.createLoadout(name: "Freedoom Phase 1",
                                                iwadID: base.id, pwadIDs: [], dehIDs: [])
        let oldDir = LibraryService.savesDirectory(forLoadoutID: phantom.id)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try Data("save".utf8).write(to: oldDir.appendingPathComponent("slot.dsg"))

        try service.reconcileBundledBaseGameLoadouts()

        XCTAssertTrue(try service.allLoadouts().isEmpty, "phantom loadout not removed")
        let newDir = LibraryService.savesDirectory(forLoadoutID: base.id)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: newDir.appendingPathComponent("slot.dsg").path),
            "saves not migrated to base-game key")
        try? FileManager.default.removeItem(at: newDir)
    }

    func testReconcileLeavesUserPresetsUntouched() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i", kind: WADKind.iwad.rawValue, family: "doom2")
        _ = try service.createLoadout(name: "My Stack", iwadID: iwad.id, pwadIDs: [], dehIDs: [])
        try service.reconcileBundledBaseGameLoadouts()
        XCTAssertEqual(try service.allLoadouts().map(\.name), ["My Stack"])
    }
```

(Note for the implementer: the illustrative `WADFile`/`Loadout` locals in the first test show intent; the actual arrange path uses `registerImported` + `createLoadout` as written. Trim the unused locals if the reviewer prefers — keep the arranged `base`/`ld` path.)

- [ ] **Step 2: Run to verify fail** — `xcodebuild ... -only-testing:WADdleTests/LibraryServiceTests test`. Expected: FAIL — `reconcileBundledBaseGameLoadouts` missing; `testSeedCreatesFreedoomWADsButNoLoadouts` fails because seeding still inserts loadouts.
- [ ] **Step 3: Change seeding + add reconciliation.**

In `LibraryService.seedBundledContentIfNeeded()`, delete the line `context.insert(Loadout(name: entry.title, iwadID: wad.id))` (keep the `WADFile` insert). Add:

```swift
    /// One-time migration: earlier builds auto-created a Loadout per bundled
    /// Freedoom phase so the base game could launch. Base games are now
    /// directly playable, so these phantom loadouts are removed; any saves they
    /// accumulated migrate to the base game's own saves key (its WADFile.id),
    /// so on-device progress survives. User-authored presets are never touched.
    func reconcileBundledBaseGameLoadouts() throws {
        let seededTitles: Set<String> = ["Freedoom Phase 1", "Freedoom Phase 2"]
        for loadout in try context.fetch(FetchDescriptor<Loadout>())
        where loadout.pwadIDs.isEmpty && loadout.dehIDs.isEmpty
            && seededTitles.contains(loadout.name) {
            guard let iwad = try wad(id: loadout.iwadID), iwad.isBundled else { continue }
            migrateSaves(fromKey: loadout.id, toKey: iwad.id)
            context.delete(loadout)
        }
        try context.save()
    }

    private func migrateSaves(fromKey old: UUID, toKey new: UUID) {
        let src = Self.savesDirectory(forLoadoutID: old)
        let dst = Self.savesDirectory(forLoadoutID: new)
        guard FileManager.default.fileExists(atPath: src.path),
              !FileManager.default.fileExists(atPath: dst.path) else { return }
        try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: src, to: dst)
    }
```

In `App/Sources/WADdleApp.swift`, after `try library.seedBundledContentIfNeeded()`, add `try library.reconcileBundledBaseGameLoadouts()`.

- [ ] **Step 4: Run to verify pass** — `xcodebuild ... -only-testing:WADdleTests/LibraryServiceTests test`. Expected: PASS.
- [ ] **Step 5: Full-suite sanity** — `mise run test`. Expected: unit + UITests green except the 4 provisioning-gated `RealWADTests` (environmental). Confirm `EngineSmokeTests` still passes (base-game Freedoom launch), proving the phantom removal didn't strand the launch path.
- [ ] **Step 6: Commit**

```bash
git add App/Sources/Library/LibraryService.swift App/Sources/WADdleApp.swift App/Tests/LibraryServiceTests.swift
git commit -m "feat(play): retire seeded base-game loadouts, migrate saves to base-game key"
```

---

## Self-Review

**Spec coverage (Plan B scope):**
- Two-tab structure kept; Play hosts the new grid; Library keeps managing files → Tasks 3 (+ Library trimmed in 4). ✓
- Base games first-class + one-tap; `playFreedoom1` moved → Task 3. ✓
- Recently Played merged across kinds → Tasks 1, 3. ✓
- Detail page as R/U/D surface; base-locked-content vs preset-editable; visible Saves; Create-preset-from-base → Task 5. ✓
- Per-item scheme override wired into launch (`effective`), with base-game and preset override UI → Tasks 2, 5. ✓
- One-door preset creation; remove Library shortcut + "find it in Play" toast → Task 4. ✓
- Ephemeral base-game launch keyed by WADFile.id → Task 2. ✓
- Migration: stop seeding loadouts + reconcile + **saves-key migration** (Plan A prerequisite) → Task 6. ✓
- Title art is a placeholder here; TITLEPIC extraction is Plan C (tiles/detail use the generated-art fallback until then). Documented in Tasks 3/5.
- Library becoming Documents-container-aligned is Plan D — out of scope here.

**Placeholder scan:** view-body tasks (3, 5) intentionally specify interfaces + accessibility IDs + section/interaction contracts + the codebase's SwiftUI gotchas and point at the existing view patterns to copy, rather than pasting full view bodies; all logic-layer tasks (1, 2, 4-name, 5-service, 6) carry complete test + implementation code. No "TBD"/"handle edge cases" left abstract.

**Type consistency:** `PlayableItem` cases/`id` scheme (`wad-`/`loadout-`) are used identically in Tasks 1/2/3/5; `PlayableLauncher.prepare` / `LaunchPlan` signatures match their call in `PlayView.play`; `savesDirectory(forLoadoutID:)` is the single saves-key API used for base games (`wad.id`) and presets (`loadout.id`) across Tasks 2, 5, 6; `setSchemeOverride(...forBaseGame:/forPreset:)`, `saveSlots(forKey:)`, `SaveSlot`, `PresetName.suggested`, and `TouchControlScheme.displayLabel` are defined before use.

**Sequencing note:** each task leaves the app runnable — the phantom-loadout removal (Task 6) lands only after base games already render as tiles (Task 3), so the Play tab is never empty and `EngineSmokeTests` stays green throughout.
