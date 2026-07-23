# Play & Library Rework — Plan A: Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the additive data-model, controls-resolution, and launch-argument primitives the Play/Library rework needs, with zero behavior regressions.

**Architecture:** Four additive changes — `lastPlayed` on `WADFile`; an optional per-item touch-scheme override on both `WADFile` and `Loadout` plus a pure `effective(override:)` resolver; an ephemeral (no-persisted-`Loadout`) argv builder keyed by any save id; and plumbing the resolved scheme from `EngineSession.play` through `OverlayPresenter`. Nothing existing changes behavior — every new parameter is defaulted, and seeding/migration/UI are untouched (they belong to Plan B).

**Tech Stack:** Swift 6, SwiftUI, SwiftData, XCTest, XcodeGen, Woof! engine (`WoofEngine.xcframework`). Spec: `docs/superpowers/specs/2026-07-23-play-library-rework-design.md`.

## Global Constraints

- **Commits:** signed (1Password SSH). Signing can intermittently hang — retry (e.g. `for i in $(seq 10); do git commit ... && break || sleep 15; done`); never fall back to unsigned without asking.
- **Commit/PR text:** NO Claude/AI attribution, no `Co-Authored-By` line, no mention of AI tooling.
- **Additive only:** every existing unit test and UITest must still pass unchanged. New parameters must be defaulted so current call sites compile and behave identically.
- **Test command (full suite):** `mise run test` → `xcodebuild -project App/WADdle.xcodeproj -scheme WADdle -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`.
- **Single-test command:** `xcodebuild -project App/WADdle.xcodeproj -scheme WADdle -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WADdleTests/<Class>/<method> test`.
- **All new tests in this plan go into EXISTING test files** (`App/Tests/*.swift`), so **no `mise run generate` is required** — XcodeGen globs `Tests/`, and modifying an existing file needs no project regen. (If you add a *new* file, run `mise run generate` before building.)
- **SwiftData migration:** adding new *optional* attributes to `@Model` classes is a lightweight/automatic migration — no `VersionedSchema` needed; existing on-disk rows get `nil`.
- Do not touch `seedBundledContentIfNeeded()`, `WADdleApp.init`, or any SwiftUI view in this plan — those are Plan B.

---

## File Structure

**Modified:**
- `App/Sources/Models/WADFile.swift` — add `lastPlayed: Date?` and `schemeOverrideRaw: String?`.
- `App/Sources/Models/Loadout.swift` — add `schemeOverrideRaw: String?`.
- `App/Sources/Library/LibraryService.swift` — add `markPlayed(_:at:)`.
- `App/Sources/Touch/TouchControlScheme.swift` — add `effective(override:defaults:)`.
- `App/Sources/Library/LoadoutArguments.swift` — add URL/saveID builder; refactor the `Loadout` overload onto it.
- `App/Sources/EngineSession.swift` — add defaulted `scheme:` param to `play`.
- `App/Sources/Touch/OverlayPresenter.swift` — `begin(scheme:)`; store + use the scheme at install; DEBUG getter.

**Test files modified (existing):**
- `App/Tests/LibraryServiceTests.swift`, `App/Tests/TouchControlSchemeTests.swift`, `App/Tests/LoadoutArgumentsTests.swift`, `App/Tests/EngineSessionGenerationTests.swift`.

---

## Task 1: `lastPlayed` on WADFile

Lets base games (and any directly-played item) feed a future "Recently Played" view without manufacturing a hidden `Loadout`. `Loadout.lastPlayed` already exists; this adds the parallel field for `WADFile`.

**Files:**
- Modify: `App/Sources/Models/WADFile.swift`
- Modify: `App/Sources/Library/LibraryService.swift`
- Test: `App/Tests/LibraryServiceTests.swift`

**Interfaces:**
- Consumes: `LibraryService.registerImported`, `LibraryService.wad(id:)` (existing).
- Produces: `WADFile.lastPlayed: Date?`; `LibraryService.markPlayed(_ wad: WADFile, at date: Date = .now) throws`.

- [ ] **Step 1: Write the failing test**

Add to `App/Tests/LibraryServiceTests.swift`:

```swift
func testMarkPlayedStampsLastPlayed() throws {
    let wad = try service.registerImported(filename: "doom2.wad", sha1: "i1",
                                           kind: WADKind.iwad.rawValue, family: "doom2")
    XCTAssertNil(wad.lastPlayed)
    let when = Date(timeIntervalSince1970: 1_000_000)
    try service.markPlayed(wad, at: when)
    XCTAssertEqual(try service.wad(id: wad.id)?.lastPlayed, when)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project App/WADdle.xcodeproj -scheme WADdle -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WADdleTests/LibraryServiceTests/testMarkPlayedStampsLastPlayed test`
Expected: FAIL — compile error, `value of type 'WADFile' has no member 'lastPlayed'` / no member `markPlayed`.

- [ ] **Step 3: Add the model field**

In `App/Sources/Models/WADFile.swift`, add the stored property alongside the others and initialize it in `init`:

```swift
    var importDate: Date
    var lastPlayed: Date?
```

and at the end of `init(...)`, after `self.importDate = importDate`:

```swift
        self.lastPlayed = nil
```

- [ ] **Step 4: Add the mutation**

In `App/Sources/Library/LibraryService.swift`, under `// MARK: Mutations`, add:

```swift
    /// Stamps a directly-played WAD's `lastPlayed` (base games launch without
    /// a persisted Loadout, so recency is tracked on the file itself). Date is
    /// injectable for deterministic tests.
    func markPlayed(_ wad: WADFile, at date: Date = .now) throws {
        wad.lastPlayed = date
        try context.save()
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -project App/WADdle.xcodeproj -scheme WADdle -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WADdleTests/LibraryServiceTests/testMarkPlayedStampsLastPlayed test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Models/WADFile.swift App/Sources/Library/LibraryService.swift App/Tests/LibraryServiceTests.swift
git commit -m "feat(library): track lastPlayed on WADFile"
```

---

## Task 2: Per-item scheme override + `effective(override:)`

Adds the optional per-item touch-scheme override to both playable model types and the pure resolver Plan B will call at launch. Feel (tuning) stays global — only the discrete scheme is per-item.

**Files:**
- Modify: `App/Sources/Models/WADFile.swift`
- Modify: `App/Sources/Models/Loadout.swift`
- Modify: `App/Sources/Touch/TouchControlScheme.swift`
- Test: `App/Tests/TouchControlSchemeTests.swift`, `App/Tests/LibraryServiceTests.swift`

**Interfaces:**
- Consumes: `TouchControlScheme.current(defaults:)`, `TouchControlScheme.userDefaultsKey`, `withEmptyDefaults` (existing test helper in `TouchControlSchemeTests.swift`).
- Produces: `WADFile.schemeOverrideRaw: String?`; `Loadout.schemeOverrideRaw: String?`; `static TouchControlScheme.effective(override raw: String?, defaults: UserDefaults = .standard) -> TouchControlScheme`.

- [ ] **Step 1: Write the failing tests**

Add to `App/Tests/TouchControlSchemeTests.swift`:

```swift
    // MARK: Per-item effective override

    func testEffectiveOverrideWinsOverGlobalDefault() {
        withEmptyDefaults { defaults in
            defaults.set(TouchControlScheme.classic.rawValue, forKey: TouchControlScheme.userDefaultsKey)
            XCTAssertEqual(
                TouchControlScheme.effective(override: TouchControlScheme.modern.rawValue, defaults: defaults),
                .modern)
        }
    }

    func testEffectiveNilOverrideFallsToGlobal() {
        withEmptyDefaults { defaults in
            defaults.set(TouchControlScheme.modern.rawValue, forKey: TouchControlScheme.userDefaultsKey)
            XCTAssertEqual(TouchControlScheme.effective(override: nil, defaults: defaults), .modern)
        }
    }

    func testEffectiveInvalidOverrideFallsToGlobal() {
        withEmptyDefaults { defaults in
            defaults.set(TouchControlScheme.classic.rawValue, forKey: TouchControlScheme.userDefaultsKey)
            XCTAssertEqual(TouchControlScheme.effective(override: "bogus", defaults: defaults), .classic)
        }
    }
```

Add to `App/Tests/LibraryServiceTests.swift`:

```swift
    func testLoadoutSchemeOverridePersists() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i1",
                                                kind: WADKind.iwad.rawValue, family: "doom2")
        let loadout = try service.createLoadout(name: "L", iwadID: iwad.id, pwadIDs: [], dehIDs: [])
        loadout.schemeOverrideRaw = TouchControlScheme.modern.rawValue
        try service.saveChanges()
        XCTAssertEqual(try service.allLoadouts().first?.schemeOverrideRaw,
                       TouchControlScheme.modern.rawValue)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project App/WADdle.xcodeproj -scheme WADdle -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WADdleTests/TouchControlSchemeTests -only-testing:WADdleTests/LibraryServiceTests/testLoadoutSchemeOverridePersists test`
Expected: FAIL — no member `schemeOverrideRaw`; no static `effective`.

- [ ] **Step 3: Add the model fields**

In `App/Sources/Models/WADFile.swift`, add after `lastPlayed`:

```swift
    var lastPlayed: Date?
    /// Optional per-item touch-scheme override (TouchControlScheme raw value);
    /// nil = use the global default. Only meaningful for playable IWADs.
    var schemeOverrideRaw: String?
```

and in `init`, after `self.lastPlayed = nil`:

```swift
        self.schemeOverrideRaw = nil
```

In `App/Sources/Models/Loadout.swift`, add after `createdAt`:

```swift
    var createdAt: Date
    /// Optional per-preset touch-scheme override (TouchControlScheme raw
    /// value); nil = use the global default.
    var schemeOverrideRaw: String?
```

and in `init`, after `self.createdAt = createdAt`:

```swift
        self.schemeOverrideRaw = nil
```

- [ ] **Step 4: Add the resolver**

In `App/Sources/Touch/TouchControlScheme.swift`, add inside the `enum TouchControlScheme` body, after `current(defaults:)`:

```swift
    /// Resolves a playable item's optional per-item override against the
    /// global default: a non-nil, valid override wins over the global default.
    /// The DEBUG `WADDLE_TOUCH_SCHEME` test-seam still wins over everything
    /// (delegating to `current`) so UITests stay deterministic regardless of
    /// any item override.
    static func effective(override raw: String?,
                          defaults: UserDefaults = .standard) -> TouchControlScheme {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WADDLE_TOUCH_SCHEME"] != nil {
            return current(defaults: defaults)
        }
        #endif
        if let raw, let scheme = TouchControlScheme(rawValue: raw) { return scheme }
        return current(defaults: defaults)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -project App/WADdle.xcodeproj -scheme WADdle -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WADdleTests/TouchControlSchemeTests -only-testing:WADdleTests/LibraryServiceTests/testLoadoutSchemeOverridePersists test`
Expected: PASS (all TouchControlSchemeTests + the new persistence test).

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Models/WADFile.swift App/Sources/Models/Loadout.swift App/Sources/Touch/TouchControlScheme.swift App/Tests/TouchControlSchemeTests.swift App/Tests/LibraryServiceTests.swift
git commit -m "feat(touch): per-item scheme override with effective resolver"
```

---

## Task 3: Ephemeral argv builder

A base game must launch without a persisted `Loadout`. This adds a lower-level builder taking already-resolved URLs plus an explicit saves key (a base game uses its own `WADFile.id`, giving it a stable saves directory), and refactors the existing `Loadout` overload onto it (DRY). The existing `build(loadout:resolve:)` signature is unchanged, so `LoadoutArgumentsTests` and `LoadoutGridView` keep compiling.

**Files:**
- Modify: `App/Sources/Library/LoadoutArguments.swift`
- Test: `App/Tests/LoadoutArgumentsTests.swift`

**Interfaces:**
- Consumes: `LibraryService.savesDirectory(forLoadoutID:)` (existing; accepts any UUID).
- Produces: `static LoadoutArguments.build(iwadURL: URL, saveID: UUID, pwadURLs: [URL] = [], dehURLs: [URL] = [], complevel: String? = nil) throws -> [String]`. The existing `build(loadout:resolve:)` now delegates to it.

- [ ] **Step 1: Write the failing test**

Add to `App/Tests/LoadoutArgumentsTests.swift`:

```swift
    func testBuildBaseGameOnlyArgv() throws {
        let args = try LoadoutArguments.build(
            iwadURL: URL(fileURLWithPath: "/tmp/doom2.wad"), saveID: UUID())
        XCTAssertEqual(Array(args.prefix(3)), ["woof", "-iwad", "/tmp/doom2.wad"])
        XCTAssertFalse(args.contains("-file"))
        XCTAssertFalse(args.contains("-deh"))
        XCTAssertFalse(args.contains("-complevel"))
        XCTAssertTrue(args.contains("-save"))
    }

    func testBuildWithPWADsAndComplevel() throws {
        let args = try LoadoutArguments.build(
            iwadURL: URL(fileURLWithPath: "/tmp/doom2.wad"), saveID: UUID(),
            pwadURLs: [URL(fileURLWithPath: "/tmp/sunlust.wad")], complevel: "mbf21")
        XCTAssertEqual(args[args.firstIndex(of: "-file")! + 1], "/tmp/sunlust.wad")
        XCTAssertEqual(args[args.firstIndex(of: "-complevel")! + 1], "mbf21")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project App/WADdle.xcodeproj -scheme WADdle -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WADdleTests/LoadoutArgumentsTests/testBuildBaseGameOnlyArgv -only-testing:WADdleTests/LoadoutArgumentsTests/testBuildWithPWADsAndComplevel test`
Expected: FAIL — no matching `build(iwadURL:saveID:...)` overload.

- [ ] **Step 3: Add the builder and refactor the existing overload**

Replace the body of `enum LoadoutArguments` in `App/Sources/Library/LoadoutArguments.swift` with:

```swift
enum LoadoutArguments {
    /// Builds argv from already-resolved file URLs and an explicit saves key.
    /// Used by the `Loadout` overload (saveID = loadout.id) and by ephemeral
    /// base-game launches (saveID = the IWAD's WADFile.id), so each base game
    /// keeps its own stable saves directory without a persisted Loadout.
    static func build(iwadURL: URL, saveID: UUID, pwadURLs: [URL] = [],
                      dehURLs: [URL] = [], complevel: String? = nil) throws -> [String] {
        var args = ["woof", "-iwad", iwadURL.path]
        if !pwadURLs.isEmpty {
            args.append("-file")
            for url in pwadURLs { args.append(url.path) }
        }
        if !dehURLs.isEmpty {
            args.append("-deh")
            for url in dehURLs { args.append(url.path) }
        }
        let saves = LibraryService.savesDirectory(forLoadoutID: saveID)
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        args += ["-save", saves.path]
        if let complevel { args += ["-complevel", complevel] }   // vanilla|boom|mbf|mbf21
        return args
    }

    static func build(loadout: Loadout, resolve: (UUID) throws -> URL) throws -> [String] {
        let iwadURL = try resolve(loadout.iwadID)
        let pwadURLs = try loadout.pwadIDs.map { try resolve($0) }
        let dehURLs = try loadout.dehIDs.map { try resolve($0) }
        return try build(iwadURL: iwadURL, saveID: loadout.id,
                         pwadURLs: pwadURLs, dehURLs: dehURLs, complevel: loadout.complevel)
    }
}
```

(Leave the `LoadoutArgumentsError` enum above it unchanged.)

- [ ] **Step 4: Run the full LoadoutArguments suite to verify pass + parity**

Run: `xcodebuild -project App/WADdle.xcodeproj -scheme WADdle -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WADdleTests/LoadoutArgumentsTests test`
Expected: PASS — both new tests and all pre-existing `LoadoutArgumentsTests` (parity of the refactored `Loadout` overload).

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Library/LoadoutArguments.swift App/Tests/LoadoutArgumentsTests.swift
git commit -m "feat(launch): ephemeral argv builder for base-game launches"
```

---

## Task 4: Thread the effective scheme through the session

`OverlayPresenter` currently reads `TouchControlScheme.current()` directly at install. This makes the scheme an input: `EngineSession.play(arguments:scheme:)` (defaulted to `current()` for back-compat) passes it to `OverlayPresenter.begin(scheme:)`, which stores it and uses it at install. Plan B will pass `effective(override:)`; today's global behavior is preserved by the default.

**Files:**
- Modify: `App/Sources/Touch/OverlayPresenter.swift`
- Modify: `App/Sources/EngineSession.swift`
- Test: `App/Tests/EngineSessionGenerationTests.swift`

**Interfaces:**
- Consumes: `TouchControlScheme.current()` (existing); `OverlayPresenter.shared` (existing).
- Produces: `OverlayPresenter.begin(scheme: TouchControlScheme)` (replaces `begin()`); DEBUG-only `OverlayPresenter.installSchemeForTesting: TouchControlScheme`; `EngineSession.play(arguments:scheme:)` with `scheme` defaulted to `TouchControlScheme.current()`.

- [ ] **Step 1: Write the failing test**

Add to `App/Tests/EngineSessionGenerationTests.swift`:

```swift
    @MainActor
    func testOverlayBeginStoresEffectiveScheme() {
        OverlayPresenter.shared.begin(scheme: .modern)
        XCTAssertEqual(OverlayPresenter.shared.installSchemeForTesting, .modern)
        OverlayPresenter.shared.end()

        OverlayPresenter.shared.begin(scheme: .classic)
        XCTAssertEqual(OverlayPresenter.shared.installSchemeForTesting, .classic)
        OverlayPresenter.shared.end()
    }
```

(If `EngineSessionGenerationTests` is not already `@MainActor` at the class level, the per-method `@MainActor` above is sufficient; `OverlayPresenter` is `@MainActor`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project App/WADdle.xcodeproj -scheme WADdle -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WADdleTests/EngineSessionGenerationTests/testOverlayBeginStoresEffectiveScheme test`
Expected: FAIL — `begin` takes no argument `scheme`; no member `installSchemeForTesting`.

- [ ] **Step 3: Make the scheme an input to OverlayPresenter**

In `App/Sources/Touch/OverlayPresenter.swift`:

Add a stored property near the other private state (after `private var observerTokens: [NSObjectProtocol] = []`):

```swift
    private var observerTokens: [NSObjectProtocol] = []
    /// The scheme to install with, supplied by `begin(scheme:)` — replaces the
    /// old read-at-install of `TouchControlScheme.current()` so a per-item
    /// override can flow in from the launch site.
    private var installScheme: TouchControlScheme = TouchControlScheme.defaultScheme

    #if DEBUG
    var installSchemeForTesting: TouchControlScheme { installScheme }
    #endif
```

Change `func begin() {` to:

```swift
    func begin(scheme: TouchControlScheme) {
        end() // safety: never double-install
        installScheme = scheme
```

(Leave the rest of `begin`'s body — the timer and observer registration — unchanged.)

In `tryInstall()`, replace:

```swift
        let scheme = TouchControlScheme.current()
```

with:

```swift
        let scheme = installScheme
```

- [ ] **Step 4: Pass the scheme from EngineSession**

In `App/Sources/EngineSession.swift`, change the signature:

```swift
    @discardableResult
    static func play(arguments: [String],
                     scheme: TouchControlScheme = TouchControlScheme.current()) -> Int32 {
```

and change the `begin()` call:

```swift
        isRunning = true
        OverlayPresenter.shared.begin(scheme: scheme)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -project App/WADdle.xcodeproj -scheme WADdle -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WADdleTests/EngineSessionGenerationTests/testOverlayBeginStoresEffectiveScheme test`
Expected: PASS.

- [ ] **Step 6: Run the full suite to confirm no regressions**

Run: `mise run test`
Expected: PASS — entire `WADdleTests` + `WADdleUITests` green, including `TouchControlsTests` (the `WADDLE_TOUCH_SCHEME` seam still resolves via the defaulted `current()`).

- [ ] **Step 7: Commit**

```bash
git add App/Sources/Touch/OverlayPresenter.swift App/Sources/EngineSession.swift App/Tests/EngineSessionGenerationTests.swift
git commit -m "feat(touch): thread effective scheme through session install"
```

---

## Self-Review

**Spec coverage (Plan A slice):**
- `lastPlayed` on WADFile → Task 1. ✓
- Per-preset scheme override (`Loadout`) + base-game override (`WADFile`) → Task 2 (both as model fields — the spec's "lightweight model" option, chosen over a parallel UserDefaults keyed store for consistency). ✓
- `override ?? global` effective resolution + debug-seam precedence → Task 2 (`effective`). ✓
- Effective scheme reaches `OverlayPresenter` instead of a direct global read → Task 4. ✓
- Ephemeral base-game launch (no persisted Loadout; per-game saves key) → Task 3. ✓
- **Deferred to Plan B (intentional):** stop auto-creating Freedoom loadouts + reconciliation + save migration; Play/Library UI; title art; Documents-aligned Library. Called out in the header and the intro message.

**Placeholder scan:** none — every step shows exact code/commands.

**Type consistency:** `schemeOverrideRaw: String?` used identically on both models and read by `effective(override:)`; `build(iwadURL:saveID:pwadURLs:dehURLs:complevel:)` signature matches its call in the refactored `Loadout` overload and both tests; `begin(scheme:)` / `installScheme` / `installSchemeForTesting` / `play(arguments:scheme:)` names are consistent across Task 4 and its test.
