# Plan 4: Error UX & App Store Ship Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the playable app into a submittable one: engine errors surfaced as friendly alerts, import feedback, a lone-PWAD shortcut, an About/licenses screen satisfying GPL compliance, app icon + privacy manifest, App Store metadata + screenshots, the accumulated ledger carries, and an archive ready for App Store Connect.

**Architecture:** A thin shim getter exposes Woof!'s existing `errmsg` buffer to Swift; error/import feedback flows through small observable notice types into the existing SwiftUI launcher. Ship assets (icon, privacy manifest, licenses, metadata) are committed artifacts with generation scripts. Three explicit USER GATES (icon artwork, app-name/metadata, repo-public flip) pause execution for owner decisions.

**Tech Stack:** Existing stack (Swift 6/SwiftUI, C shim, XcodeGen, mise) + `xcodebuild archive`, asset catalog, PrivacyInfo.xcprivacy.

**Context:** All of Plans 1-3 + tuning are merged; app is device-verified playable. Ledger: `.superpowers/sdd/progress.md`. Spec: `docs/superpowers/specs/2026-07-11-doom-ios-design.md` (§5 error handling, §7 compliance).

## Global Constraints

- iOS 26.0 target, Xcode 26.2, simulator "iPhone 17 Pro" (iOS 26.2); `mise run bootstrap` is the canonical setup; ALL commands foreground with explicit timeouts (max 600000ms).
- Commit messages: plain conventional, **no Co-Authored-By, no Claude/AI mention**. 1Password signing may hang: retry loop (10×15s), NEVER `--no-gpg-sign`.
- Never commit: `Vendor/`, `App/Resources/GameData/`, `App/Resources/woof.pk3`, `App/*.xcodeproj`, `App/Info.plist`, `App/Sources/Generated/`, test WADs.
- Engine edits only in `Engine/woof/src/woof_ios.{h,c}` unless documented in `Engine/WOOF_UPSTREAM.md`; rebuild via `Scripts/build-engine.sh` after any engine change.
- Standing gate: `xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:BoomBoxTests -only-testing:BoomBoxUITests/EngineSmokeTests -only-testing:BoomBoxUITests/TouchControlsTests test` → TEST SUCCEEDED (90 unit + 4 UI as of merge). Don't run two xcodebuild sessions against one simulator.
- Signing: `DEVELOPMENT_TEAM: 352UZEKYPP`, `CODE_SIGN_STYLE: Automatic` (already in project.yml).
- Licensing posture (spec §7): app + engine fork under GPL-2.0; Freedoom BSD; SDL3 zlib; OpenAL Soft **LGPL-2.0 (conveyed under GPL per LGPL §3 since the full app is GPL and source is published)**; ZIPFoundation MIT. Free app, no analytics, no network calls.
- USER GATES: tasks 5 (icon), 7 (name/metadata), 8 (repo public + archive) each contain an explicit stop-and-ask step — the executing controller must get the owner's approval there, not improvise.

## File Structure

```
Engine/woof/src/woof_ios.{h,c}       (modify: WoofIOS_LastErrorMessage + I_AtSignal-growth fix note)
Engine/woof/src/i_exit.c             (modify: free drained I_AtSignal entries under WOOF_IOS)
App/Sources/EngineSession.swift      (modify: guard not precondition; lastErrorMessage capture)
App/Sources/UI/EngineErrorAlert.swift (new: error presentation model + hint mapping)
App/Sources/UI/LoadoutGridView.swift (modify: error alert + lone-PWAD shortcut consumption)
App/Sources/Library/ImportNotices.swift (new: observable import/adoption notice hub)
App/Sources/UI/LibraryView.swift     (modify: notice display + refresh on external import)
App/Sources/BoomBoxApp.swift         (modify: adoption outcome → notices)
App/Sources/UI/AboutView.swift       (new: version/engine/licenses/source-link screen)
App/Resources/Licenses/*.txt         (new, committed: license texts + NOTICES)
App/Assets.xcassets/                 (new: AppIcon)
Scripts/generate-app-icon.swift      (new: deterministic icon renderer)
App/PrivacyInfo.xcprivacy            (new, committed)
App/project.yml                      (modify: assets, privacy manifest, icon setting)
docs/app-store/metadata.md           (new: name/subtitle/description/keywords/age-rating draft)
docs/app-store/submission-checklist.md (new)
Scripts/capture-screenshots.sh       (new)
Scripts/archive.sh + App/ExportOptions.plist (new)
```

---

### Task 1: Engine error text → Swift

**Files:**
- Modify: `Engine/woof/src/woof_ios.h`, `Engine/woof/src/woof_ios.c`
- Modify: `App/Sources/EngineSession.swift`
- Create: `App/Sources/UI/EngineErrorAlert.swift`
- Create: `App/Tests/EngineErrorAlertTests.swift`

**Interfaces:**
- Produces C: `const char *WoofIOS_LastErrorMessage(void);` — returns the engine's `errmsg` buffer (empty string when the last exit was clean). Valid until the next session starts (next `WoofIOS_Run` resets it via the existing `I_ResetErrorMessages()`).
- Produces Swift:
```swift
// EngineSession addition:
private(set) static var lastErrorMessage: String?   // nil on clean exit
// EngineErrorAlert:
struct EngineErrorAlert: Equatable {
    let title: String            // "Couldn't run this loadout"
    let engineMessage: String    // raw engine text
    let hint: String?            // human hint or nil
    static func from(exitCode: Int32, engineMessage: String?) -> EngineErrorAlert? // nil when exitCode == 0
}
```

- [ ] **Step 1: Shim getter**

`woof_ios.h` (append near the other debug functions):
```c
// Last engine error text (Woof!'s i_system.c errmsg buffer). Empty string
// when the previous session exited cleanly. Reset at each session start.
const char *WoofIOS_LastErrorMessage(void);
```
`woof_ios.c`:
```c
const char *WoofIOS_LastErrorMessage(void)
{
    extern const char *I_GetErrorMessage(void);
    return I_GetErrorMessage();
}
```
Check `Engine/woof/src/i_system.c` for an existing accessor; if none exists, add one next to `I_ResetErrorMessages` (both are already in our iOS patch set for this file — extend the same patch):
```c
const char *I_GetErrorMessage(void)
{
    return errmsg;
}
```
with the matching declaration in `i_system.h` guarded the same way the reset is. Update `Engine/WOOF_UPSTREAM.md`'s i_system.c bullet. Rebuild: `Scripts/build-engine.sh`; verify `nm` shows `WoofIOS_LastErrorMessage` in both slices.

- [ ] **Step 2: Failing tests for the alert mapping**

`App/Tests/EngineErrorAlertTests.swift`:
```swift
import XCTest
@testable import BoomBox

final class EngineErrorAlertTests: XCTestCase {
    func testCleanExitProducesNoAlert() {
        XCTAssertNil(EngineErrorAlert.from(exitCode: 0, engineMessage: nil))
    }

    func testErrorExitCarriesEngineText() {
        let alert = EngineErrorAlert.from(exitCode: -1,
                                          engineMessage: "Unknown or invalid IWAD file.")
        XCTAssertEqual(alert?.engineMessage, "Unknown or invalid IWAD file.")
        XCTAssertNotNil(alert?.hint)   // IWAD problems get a hint
    }

    func testWrongIWADHint() {
        let alert = EngineErrorAlert.from(exitCode: -1,
                                          engineMessage: "W_GetNumForName: TEXTURE2 not found")
        XCTAssertEqual(alert?.hint,
            "This usually means the WAD needs a different base game (IWAD). Try pairing it with Doom II / Freedoom Phase 2.")
    }

    func testUnknownErrorHasNoHintButStillAlerts() {
        let alert = EngineErrorAlert.from(exitCode: -1, engineMessage: "Z_Malloc: failure")
        XCTAssertNil(alert?.hint)
        XCTAssertEqual(alert?.title, "Couldn't run this loadout")
    }

    func testMissingMessageGetsGenericText() {
        let alert = EngineErrorAlert.from(exitCode: -101, engineMessage: nil)
        XCTAssertEqual(alert?.engineMessage, "The engine reported no details (exit code -101).")
    }
}
```
Run unit suite → FAIL (type not found).

- [ ] **Step 3: Implement EngineErrorAlert**

`App/Sources/UI/EngineErrorAlert.swift`:
```swift
import Foundation

/// Maps an engine exit into user-facing alert content (spec §5: show the
/// engine's actual error text, plus a hint when it smells like a wrong-IWAD
/// pairing; a bad WAD must never crash the app).
struct EngineErrorAlert: Equatable {
    let title: String
    let engineMessage: String
    let hint: String?

    static func from(exitCode: Int32, engineMessage: String?) -> EngineErrorAlert? {
        guard exitCode != 0 else { return nil }
        let message = (engineMessage?.isEmpty == false)
            ? engineMessage!
            : "The engine reported no details (exit code \(exitCode))."
        return EngineErrorAlert(title: "Couldn't run this loadout",
                                engineMessage: message,
                                hint: hint(for: message))
    }

    private static func hint(for message: String) -> String? {
        let wrongIWADMarkers = ["W_GetNumForName", "not found", "Unknown or invalid IWAD"]
        if wrongIWADMarkers.contains(where: message.contains) {
            if message.contains("IWAD") {
                return "The base game file wasn't recognized. Pick a supported IWAD (Doom, Doom II, Freedoom…) for this loadout."
            }
            return "This usually means the WAD needs a different base game (IWAD). Try pairing it with Doom II / Freedoom Phase 2."
        }
        return nil
    }
}
```
Note: the two IWAD-related branches must satisfy the two distinct test expectations above — `Unknown or invalid IWAD` hits the first branch, `W_GetNumForName…not found` the second.

- [ ] **Step 4: Capture the message in EngineSession + guard-not-precondition**

In `EngineSession.play(arguments:)`: replace `precondition(!isRunning, ...)` with
```swift
        guard !isRunning else { return -102 }  // defense-in-depth: never crash (ledger item)
```
(keep the argv precondition), and after `WoofIOS_Run` returns:
```swift
        let code = WoofIOS_Run(Int32(arguments.count), &argv)
        lastErrorMessage = code == 0 ? nil
            : String(cString: WoofIOS_LastErrorMessage())
        return code
```
(add `private(set) static var lastErrorMessage: String?`).

- [ ] **Step 5: Present the alert in LoadoutGridView**

In `LoadoutGridView`: add `@State private var errorAlert: EngineErrorAlert?`; in `play(_:)` after the session returns:
```swift
            lastExitCode = EngineSession.play(arguments: args)
            errorAlert = EngineErrorAlert.from(exitCode: lastExitCode ?? 0,
                                               engineMessage: EngineSession.lastErrorMessage)
```
(also map the `-101` arg-build failure through the same path with message "A file in this loadout is missing from the library.") and attach:
```swift
            .alert(errorAlert?.title ?? "", isPresented: Binding(
                get: { errorAlert != nil }, set: { if !$0 { errorAlert = nil } }
            ), presenting: errorAlert) { _ in
                Button("OK") { errorAlert = nil }
            } message: { alert in
                Text([alert.engineMessage, alert.hint].compactMap { $0 }
                    .joined(separator: "\n\n"))
            }
```

- [ ] **Step 6: UITest — the bad-IWAD loadout now alerts**

Extend `RealWADTests.testUnrecognizedIWADFailsSoft` (it already boots the synthetic bad IWAD): after the nonzero-exit assertion, add
```swift
        let alert = app.alerts["Couldn't run this loadout"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5),
                      "engine error alert not shown")
        alert.buttons["OK"].tap()
```
Run gates: unit suite; RealWADTests (provision first if simulator lacks WADs); standing gate. All green.

- [ ] **Step 7: Commit**

```bash
git add Engine/woof/src Engine/WOOF_UPSTREAM.md App/Sources App/Tests App/UITests
git commit -m "feat: surface engine error text as launcher alerts with pairing hints"
```

---

### Task 2: Import & adoption feedback

**Files:**
- Create: `App/Sources/Library/ImportNotices.swift`
- Modify: `App/Sources/BoomBoxApp.swift`, `App/Sources/UI/LibraryView.swift`, `App/Sources/ContentView.swift`
- Create: `App/Tests/ImportNoticesTests.swift`

**Interfaces:**
- Produces:
```swift
@MainActor @Observable final class ImportNotices {
    static let shared = ImportNotices()
    private(set) var current: String?          // one-line banner text, nil = hidden
    func post(outcome: ImportOutcome)          // builds text; no-op if outcome empty
    func dismiss()
    static func summary(of outcome: ImportOutcome) -> String?  // pure, testable
}
```
- Behavior: `summary` returns e.g. `"Imported Sunlust · 1 already in library · 2 failed (moved to Import Failed)"`; nil when nothing happened. Banner shows in ContentView's overlay (auto-dismiss after 6s), so it appears no matter which tab is active — covering launch adoption AND share-sheet imports (ledgered Plan-4 items).

- [ ] **Step 1: Failing tests**

`App/Tests/ImportNoticesTests.swift`:
```swift
import XCTest
@testable import BoomBox

final class ImportNoticesTests: XCTestCase {
    func testEmptyOutcomeYieldsNil() {
        XCTAssertNil(ImportNotices.summary(of: ImportOutcome()))
    }

    func testImportOnly() {
        var outcome = ImportOutcome()
        outcome.imported = ["Sunlust"]
        XCTAssertEqual(ImportNotices.summary(of: outcome), "Imported Sunlust")
    }

    func testMixedOutcome() {
        var outcome = ImportOutcome()
        outcome.imported = ["Sunlust", "Scythe"]
        outcome.duplicates = ["Eviternity II"]
        outcome.rejected = ["junk.wad": "Not a WAD file (bad header magic)."]
        XCTAssertEqual(ImportNotices.summary(of: outcome),
            "Imported Sunlust, Scythe · 1 already in library · 1 failed (moved to Import Failed)")
    }

    func testRejectionOnly() {
        var outcome = ImportOutcome()
        outcome.rejected = ["a.wad": "x", "b.zip": "y"]
        XCTAssertEqual(ImportNotices.summary(of: outcome),
            "2 failed (moved to Import Failed)")
    }
}
```

- [ ] **Step 2: Implement**

`App/Sources/Library/ImportNotices.swift`:
```swift
import Foundation
import Observation

@MainActor
@Observable
final class ImportNotices {
    static let shared = ImportNotices()
    private(set) var current: String?
    private var dismissTask: Task<Void, Never>?

    func post(outcome: ImportOutcome) {
        guard let text = Self.summary(of: outcome) else { return }
        current = text
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { self?.current = nil }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }

    static func summary(of outcome: ImportOutcome) -> String? {
        var parts: [String] = []
        if !outcome.imported.isEmpty {
            parts.append("Imported \(outcome.imported.joined(separator: ", "))")
        }
        if !outcome.duplicates.isEmpty {
            parts.append("\(outcome.duplicates.count) already in library")
        }
        if !outcome.rejected.isEmpty {
            parts.append("\(outcome.rejected.count) failed (moved to Import Failed)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
```

- [ ] **Step 3: Wire the sources**

`BoomBoxApp.swift`: `.task { ImportNotices.shared.post(outcome: await importer.adoptLooseFiles()) }` and the `.onOpenURL` handler becomes
```swift
            .onOpenURL { url in
                let outcome = importer.importFiles(at: [url])
                ImportNotices.shared.post(outcome: outcome)
                NotificationCenter.default.post(name: .libraryDidChange, object: nil)
            }
```
Add in `ImportNotices.swift`:
```swift
extension Notification.Name {
    static let libraryDidChange = Notification.Name("libraryDidChange")
}
```
`LibraryView`: also `post` the outcome from the in-app picker (keep its detail alert), and refresh on `.libraryDidChange` (`.onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in refresh() }`) — closing the ledgered "share-sheet import doesn't refresh LibraryView" item.
`ContentView`: bottom overlay banner (above the exit label) when `ImportNotices.shared.current != nil`, `.accessibilityIdentifier("importNoticeBanner")`, tap to dismiss.

- [ ] **Step 4: Gates + commit**

Unit suite green (new tests included); standing gate green.
```bash
git add App/Sources App/Tests
git commit -m "feat: import and adoption feedback banner with library refresh"
```

---

### Task 3: Lone-PWAD → new loadout shortcut (spec §4)

**Files:**
- Modify: `App/Sources/UI/LibraryView.swift`
- Modify: `App/Sources/Library/LibraryService.swift`
- Create: `App/Tests/SuggestedIWADTests.swift`

**Interfaces:**
- Produces: `LibraryService.suggestedIWAD(for pwad: WADFile) throws -> WADFile?` — best IWAD for a PWAD's `gameFamilyRaw`: prefers a non-bundled IWAD of the same family, falls back to bundled Freedoom (doom1→freedoom1, doom2/unknown→freedoom2).

- [ ] **Step 1: Failing tests**

`App/Tests/SuggestedIWADTests.swift` (reuse LibraryServiceTests' in-memory container setup pattern):
```swift
import SwiftData
import XCTest
@testable import BoomBox

@MainActor
final class SuggestedIWADTests: XCTestCase {
    var service: LibraryService!
    var tmp: URL!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, configurations: config)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        service = LibraryService(context: ModelContext(container),
                                 store: WADStore(directory: tmp))
        try service.seedBundledContentIfNeeded()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testDoom2FamilyPrefersRealIWADOverFreedoom() throws {
        let doom2 = try service.registerImported(filename: "doom2.wad", sha1: "d2",
                                                 kind: "IWAD", family: "doom2")
        let pwad = try service.registerImported(filename: "sunlust.wad", sha1: "s",
                                                kind: "PWAD", family: "doom2")
        XCTAssertEqual(try service.suggestedIWAD(for: pwad)?.id, doom2.id)
    }

    func testFallsBackToBundledFreedoomByFamily() throws {
        let e1 = try service.registerImported(filename: "ep.wad", sha1: "e",
                                              kind: "PWAD", family: "doom1")
        XCTAssertEqual(try service.suggestedIWAD(for: e1)?.filename, "freedoom1.wad")
        let m1 = try service.registerImported(filename: "maps.wad", sha1: "m",
                                              kind: "PWAD", family: "doom2")
        XCTAssertEqual(try service.suggestedIWAD(for: m1)?.filename, "freedoom2.wad")
        let unk = try service.registerImported(filename: "res.wad", sha1: "u",
                                               kind: "PWAD", family: "unknown")
        XCTAssertEqual(try service.suggestedIWAD(for: unk)?.filename, "freedoom2.wad")
    }
}
```

- [ ] **Step 2: Implement**

`LibraryService`:
```swift
    /// Best-guess IWAD for a PWAD (spec §4 "New loadout with [detected IWAD]"):
    /// a user-imported IWAD of the same family wins; bundled Freedoom is the
    /// always-available fallback (doom1 -> phase 1, everything else -> phase 2).
    func suggestedIWAD(for pwad: WADFile) throws -> WADFile? {
        let iwads = try allWADs().filter { $0.kindRaw == WADKind.iwad.rawValue }
        if let match = iwads.first(where: {
            !$0.isBundled && $0.gameFamilyRaw == pwad.gameFamilyRaw
        }) {
            return match
        }
        let fallback = pwad.gameFamilyRaw == GameFamily.doom1.rawValue
            ? "freedoom1.wad" : "freedoom2.wad"
        return iwads.first { $0.isBundled && $0.filename == fallback }
    }
```

- [ ] **Step 3: UI wiring**

`LibraryView` row: for PWAD rows add a swipe action + context menu item "New Loadout" (`accessibilityIdentifier("newLoadoutFromPWAD-\(wad.displayName)")`) that calls `suggestedIWAD`, creates the loadout named after the PWAD's display name (`try? library.createLoadout(name: wad.displayName, iwadID: iwad.id, pwadIDs: [wad.id], dehIDs: [])`), posts a notice via `ImportNotices.shared` ("Created loadout Sunlust — find it in Play"), and posts `.libraryDidChange`.

- [ ] **Step 4: Gates + commit**

Unit suite + standing gate green.
```bash
git add App/Sources App/Tests
git commit -m "feat: one-tap loadout creation from a PWAD with suggested IWAD"
```

---

### Task 4: About & licenses screen (GPL compliance surface)

**Files:**
- Create: `App/Sources/UI/AboutView.swift`
- Create: `App/Resources/Licenses/` (committed): `APP-LICENSE-GPL2.txt` (copy of repo `COPYING`), `FREEDOOM-BSD.txt` (copy from the fetched `FREEDOOM-COPYING.txt` content — commit it; it's a license text, not game data), `SDL3-ZLIB.txt`, `OPENALSOFT-LGPL.txt`, `ZIPFOUNDATION-MIT.txt`, `NOTICES.md`
- Modify: `App/Sources/ContentView.swift` (About entry), `App/project.yml` (Licenses folder as resources)

**Interfaces:**
- Consumes: `BuildInfo` (commit/branch/builtAt), bundle version strings.
- Produces: About screen reachable from the Play tab gear menu, id `aboutButton` → `aboutView`.

- [ ] **Step 1: Collect license texts**

Copy verbatim: repo `COPYING` → `APP-LICENSE-GPL2.txt`; `Vendor/src/SDL/LICENSE.txt` → `SDL3-ZLIB.txt`; OpenAL Soft's `COPYING` from `Vendor/src/openal-soft/COPYING` → `OPENALSOFT-LGPL.txt`; ZIPFoundation's MIT license from the SPM checkout (`~/Library/Developer/Xcode/DerivedData/*/SourcePackages/checkouts/ZIPFoundation/LICENSE`) → `ZIPFOUNDATION-MIT.txt`; Freedoom license text from `App/Resources/GameData/FREEDOOM-COPYING.txt` → `FREEDOOM-BSD.txt`. Verify each begins with its expected license name (`head -3` each).

`NOTICES.md`:
```markdown
# Third-party notices

BoomBox is free software under the GNU GPL v2 (see APP-LICENSE-GPL2.txt).
Complete corresponding source: https://github.com/tylervick/boombox

- Woof! (Doom engine) — GPL-2.0, © Fabian Greffrath and contributors.
  Vendored with iOS patches; see Engine/WOOF_UPSTREAM.md in the source repo.
- Freedoom (game data) — BSD-style license (FREEDOOM-BSD.txt).
- SDL 3 — zlib license (SDL3-ZLIB.txt).
- OpenAL Soft — LGPL-2.0 (OPENALSOFT-LGPL.txt). Statically linked and
  conveyed as part of this GPL-2.0 application per LGPL §3 (conversion to
  GPL), with complete source available at the repository above.
- ZIPFoundation — MIT (ZIPFOUNDATION-MIT.txt).
```

- [ ] **Step 2: AboutView**

`App/Sources/UI/AboutView.swift`:
```swift
import SwiftUI

struct AboutView: View {
    private let sourceURL = URL(string: "https://github.com/tylervick/boombox")!

    var body: some View {
        List {
            Section {
                LabeledContent("Version",
                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                LabeledContent("Build", value: "\(BuildInfo.commit) (\(BuildInfo.branch))")
                LabeledContent("Engine", value: "Woof! (GPL-2.0)")
            }
            Section("Open source") {
                Link("Source code on GitHub", destination: sourceURL)
                Text("BoomBox is free software under the GNU GPL v2. It bundles Freedoom and plays your own WAD files; no game data is included from commercial releases.")
                    .font(.footnote)
            }
            Section("Licenses") {
                ForEach(licenseFiles, id: \.0) { name, file in
                    NavigationLink(name) {
                        LicenseTextView(title: name, filename: file)
                    }
                }
            }
        }
        .navigationTitle("About")
        .accessibilityIdentifier("aboutView")
    }

    private var licenseFiles: [(String, String)] {
        [("BoomBox & Woof! — GPL-2.0", "APP-LICENSE-GPL2"),
         ("Third-party notices", "NOTICES"),
         ("Freedoom — BSD", "FREEDOOM-BSD"),
         ("SDL 3 — zlib", "SDL3-ZLIB"),
         ("OpenAL Soft — LGPL-2.0", "OPENALSOFT-LGPL"),
         ("ZIPFoundation — MIT", "ZIPFOUNDATION-MIT")]
    }
}

struct LicenseTextView: View {
    let title: String
    let filename: String

    var body: some View {
        ScrollView {
            Text(loadText())
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
    }

    private func loadText() -> String {
        for ext in ["txt", "md"] {
            if let url = Bundle.main.url(forResource: filename, withExtension: ext,
                                         subdirectory: "Licenses"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }
        return "License text missing from bundle — see the GitHub repository."
    }
}
```
`project.yml`: add `- path: Resources/Licenses` as a folder-reference resource (same pattern as GameData — NOT named "Resources"). ContentView gear menu gains "About" (`aboutButton`) presenting `NavigationStack { AboutView() }` as a sheet.

- [ ] **Step 3: UITest smoke**

Add to `App/UITests/` a minimal check inside a new `ShipUITests.swift`:
```swift
import XCTest

final class ShipUITests: XCTestCase {
    @MainActor
    func testAboutScreenShowsLicensesAndBuild() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["controlsMenuButton"].tap()   // the existing gear menu trigger id — verify actual id in ContentView/LoadoutGridView and adjust
        app.buttons["aboutButton"].tap()
        XCTAssertTrue(app.otherElements["aboutView"].waitForExistence(timeout: 5)
                   || app.collectionViews.element.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["BoomBox & Woof! — GPL-2.0"].exists)
    }
}
```
(Confirm the gear menu's real accessibility id first and use it; add one if the menu trigger lacks one.)

- [ ] **Step 4: Gates + commit**

Unit + standing gate + ShipUITests green.
```bash
git add App/Sources App/Resources/Licenses App/project.yml App/UITests
git commit -m "feat: about screen with licenses, build info, and source link"
```

---

### Task 5: App icon + asset catalog — USER GATE

**Files:**
- Create: `Scripts/generate-app-icon.swift`, `App/Assets.xcassets/` (committed incl. generated PNG)
- Modify: `App/project.yml`

- [ ] **Step 1: Icon generator**

`Scripts/generate-app-icon.swift` (run with `swift Scripts/generate-app-icon.swift`): renders a deterministic 1024×1024 PNG — dark charcoal rounded field, centered upward flame mark in Doom-orange gradient (three overlapping teardrop bezier flames, #FF6A00→#FFC933), subtle vignette. No text (App Store icons shouldn't rely on it). Complete CoreGraphics implementation (~120 lines) writing to `App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`. Contents.json (single-size universal icon, iOS "single size" 1024 marketing + `"platform": "ios", "size": "1024x1024"` entries per current asset-catalog format).

`project.yml`: add `- path: Assets.xcassets` to the app target's sources, and `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` to its settings.

- [ ] **Step 2: Build + visual verify**

`xcodegen generate` + build; confirm the built app bundle contains the icon (`plutil -p` on Info.plist shows CFBundleIcons or asset-catalog compilation output exists), and screenshot the simulator home screen showing the icon. Read the PNG yourself to confirm it rendered sensibly (not blank/garbled).

- [ ] **Step 3: USER GATE — icon approval**

STOP. Show the owner the icon PNG and home-screen screenshot. Proceed only on approval; iterate the generator's palette/shape parameters on feedback. Record the decision in the report.

- [ ] **Step 4: Commit**

```bash
git add Scripts/generate-app-icon.swift App/Assets.xcassets App/project.yml
git commit -m "feat: app icon and asset catalog"
```

---

### Task 6: Privacy manifest + ship-blocking ledger fixes

**Files:**
- Create: `App/PrivacyInfo.xcprivacy`
- Modify: `App/project.yml` (bundle the manifest)
- Modify: `Engine/woof/src/i_exit.c` (I_AtSignal per-session growth), `App/Sources/EngineSession.swift` + `App/Sources/Touch/TouchControlScheme.swift` (+ any other env seams) for `#if DEBUG` gating
- Modify: `App/Sources/WAD/ZipExtractor.swift` (`precondition(maxEntryBytes >= 0)`), `App/Sources/Library/ImportService.swift` (cap string from constant)

- [ ] **Step 1: PrivacyInfo.xcprivacy**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>CA92.1</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
```
(App-scoped settings only — scheme/tuning/debug toggles; no tracking, no data collection, no network.) Add to `project.yml` sources as a file resource; verify it lands in the built bundle root.

- [ ] **Step 2: Ledger fixes**

1. `Engine/woof/src/i_exit.c` — `I_AtSignal` list grows per session (entries re-registered each `D_DoomMain`): under `#ifdef WOOF_IOS`, before appending in `I_AtSignal`, skip if `func` is already in the list (identity check loop). Document in WOOF_UPSTREAM.md; rebuild engine.
2. `#if DEBUG` gating: wrap `EngineSession.beginSessionForTesting`, and each env-seam read (`BOOMBOX_AUTOQUIT_SECONDS`, `BOOMBOX_DEBUG_INPUT_COUNTS`, `BOOMBOX_TEST_WARP`, `BOOMBOX_FORCE_TOUCH_OVERLAY`, `BOOMBOX_TOUCH_SCHEME`) in `#if DEBUG` so release builds carry no test seams. CAUTION: UITests run against the Debug configuration, so gates stay green; verify by running the standing gate after.
3. `ZipExtractor`: `precondition(maxEntryBytes >= 0, "cap must be non-negative")` at the cap-taking entry point; replace the hardcoded "512 MB" reason string with a constant-derived one (`"Entry exceeds the \(maxEntryBytes / (1024*1024)) MB import limit."` using the actual cap in effect).
4. Update the oversize tests if the message change breaks their expectations.

- [ ] **Step 3: Gates + commit**

Rebuild engine; unit suite; standing gate; all green.
```bash
git add App/PrivacyInfo.xcprivacy App/project.yml Engine/woof/src Engine/WOOF_UPSTREAM.md App/Sources App/Tests
git commit -m "feat: privacy manifest and release hardening of debug seams"
```

---

### Task 7: App Store metadata + screenshots — USER GATE

**Files:**
- Create: `docs/app-store/metadata.md`, `Scripts/capture-screenshots.sh`, `docs/app-store/screenshots/` (gitignored? NO — commit them; they're ours)

- [ ] **Step 1: Draft metadata.md**

Complete draft containing: proposed **name options** ("BoomBox — Doom Engine Player" primary; note the working name may conflict with existing trademarks — flag for owner search), subtitle ("Play classic Doom WADs"), promotional text, full description (engine lineage, Freedoom bundled, import-your-own-WADs, loadouts, touch/controller/keyboard support, open source/GPL, NO copyrighted game content included), keywords ("doom,wad,fps,retro,source port,freedoom,boom,classic"), support URL (GitHub repo), category (Games > Action), age-rating questionnaire answers (Cartoon/Fantasy Violence: Frequent/Intense; Realistic Violence: Infrequent/Mild → expected 12+/17+ depending on questionnaire version — document each answer), export compliance (uses only exempt HTTPS/no proprietary encryption → "None of the algorithms mentioned"), copyright line ("© 2026 Tyler Vick; engine GPL-2.0"), and the review note ("This app is a GPL source port. It includes only the freely-licensed Freedoom data; users may import WAD files they own via the Files app. Comparable approved apps: GenZD, RetroArch.").

- [ ] **Step 2: Screenshot capture script**

`Scripts/capture-screenshots.sh`: boots "iPhone 17 Pro Max" (6.9" class required size) and "iPad (A16)" if available, provisions WADs (reuses provision script), launches, and captures: loadout grid, library, loadout editor, Control Feel sheet, in-game Freedoom with overlay, automap. Uses `xcrun simctl io … screenshot` with the app driven by a temporary XCUITest or manual pauses (script documents which). Output to `docs/app-store/screenshots/<device>/`. Read each screenshot to verify content before finishing.

- [ ] **Step 3: USER GATE — name + metadata approval**

STOP. Present metadata.md and the screenshot set to the owner: final app name (App Store display name is a real decision — "BoomBox" availability/trademark is unverified), description tone, age answers. Iterate on feedback; record decisions in metadata.md.

- [ ] **Step 4: Commit**

```bash
git add docs/app-store Scripts/capture-screenshots.sh
git commit -m "docs: App Store metadata draft and screenshot pipeline"
```

---

### Task 8: Repo public + archive — USER GATE, then final verification

**Files:**
- Create: `Scripts/archive.sh`, `App/ExportOptions.plist`
- Create: `docs/app-store/submission-checklist.md`
- Modify: `README.md` (public-facing polish pass)

- [ ] **Step 1: Archive pipeline**

`App/ExportOptions.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>teamID</key><string>352UZEKYPP</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
```
`Scripts/archive.sh`:
```bash
#!/bin/bash
# Builds an App Store archive + .ipa. Requires a signed-in Xcode account for
# team 352UZEKYPP. Upload happens via Xcode Organizer or:
#   xcrun altool / Transporter — see docs/app-store/submission-checklist.md
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/App" && xcodegen generate && cd "$ROOT"
ARCHIVE="$ROOT/Vendor/archive/BoomBox.xcarchive"
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'generic/platform=iOS' -configuration Release \
  -archivePath "$ARCHIVE" archive
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist App/ExportOptions.plist \
  -exportPath "$ROOT/Vendor/archive/export"
echo "IPA at Vendor/archive/export/"
```
Verify: `Scripts/archive.sh` produces an .ipa; `codesign -dv` on the archived app shows the team; the release build contains NO debug seams (grep the binary: `strings ... | grep -c BOOMBOX_TEST_WARP` → 0, proving Task 6's DEBUG gating).

- [ ] **Step 2: Submission checklist doc**

`docs/app-store/submission-checklist.md`: ordered owner checklist — App Store Connect app record creation (bundle id com.tylervick.BoomBox, name from metadata.md), upload via Organizer/Transporter, attach screenshots + metadata, age questionnaire answers (from metadata.md), export compliance answer, review notes text, and the GPL posture summary (source link must be live BEFORE submission).

- [ ] **Step 3: USER GATE — flip repo public**

STOP. Confirm with the owner, then: `gh repo edit tylervick/boombox --visibility public --accept-visibility-change-consequences`. Pre-flight before asking: README reads well publicly (fresh eyes pass: no stale claims, correct build steps via mise, licenses/attribution present); no secrets in history (`gh secret list` empty; grep history for tokens: `git log -p | grep -iE 'api[_-]?key|secret|token' | head` — expect only innocuous hits, note anything suspicious to the owner); `backup-pre-resign` ref deleted after owner confirmation (ledgered as safe once confirmed).

- [ ] **Step 4: Final clean-room + full matrix**

From a scratch clone (`git clone <repo> /tmp/boombox-cleanroom && cd /tmp/boombox-cleanroom`): `mise install && mise run bootstrap`, standing gate green, provision + RealWADTests green, `Scripts/archive.sh` succeeds. This proves a stranger can build the app from the public repo — the substance of GPL compliance.

- [ ] **Step 5: Commit + wrap**

```bash
git add Scripts/archive.sh App/ExportOptions.plist docs/app-store README.md
git commit -m "feat: App Store archive pipeline and submission checklist"
```
Final ledger entry: Plan 4 complete; remaining human-only steps (App Store Connect record, upload, submit) live in submission-checklist.md.

---

## Plan self-review notes

- **Spec coverage:** §5 error surfacing incl. wrong-IWAD hint (Task 1 — engine text via the errmsg buffer + I_ResetErrorMessages already in our patch set); §4 lone-PWAD shortcut (Task 3); §7 compliance surface (Task 4 licenses + Task 8 public source + clean-room build proof); import feedback ledger items (Task 2). Deliberately NOT included: mixed-zip trade-off revision (behavior documented + quarantine-on-oversize already shipped; remaining case is corrupt-entry-only inside an otherwise-good zip — documented won't-fix in NOTICES-adjacent docs), container-init recovery beyond fatalError (needs design; risk is cold-start-only — noted in submission checklist as known limitation), Task.detached structured cancellation (no user-visible effect; carried).
- **Ledger sweep:** every open Plan-4 ledger item is either a task here (error text, adoption feedback + LibraryView refresh, lone-PWAD, I_AtSignal, DEBUG gating, 512MB string, UInt64 precondition, guard-vs-precondition, bundled pseudo-hash → covered by Task 3's suggestion UX making the duplicate question moot for the main flow) or explicitly documented as carried with rationale (above).
- **User gates:** icon (5), name/metadata (7), repo-public (8) — controller stops and asks; everything else runs continuously.
- **Type consistency:** `EngineErrorAlert.from(exitCode:engineMessage:)` matches Task 1 Steps 2/3/5; `ImportNotices.summary/post` matches Tasks 2/3 usage; `suggestedIWAD(for:)` naming consistent; `WoofIOS_LastErrorMessage` C name consistent across shim/Swift.
- **Grounded:** errmsg buffer + reset verified in i_system.c; DEVELOPMENT_TEAM 352UZEKYPP + automatic signing already in project.yml; UserDefaults is the only privacy-manifest-relevant API in App/Sources; no asset catalog exists today; OpenAL Soft LGPL conveyed-under-GPL noted per its COPYING.
