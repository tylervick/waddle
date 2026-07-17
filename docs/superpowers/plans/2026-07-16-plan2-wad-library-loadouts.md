# Plan 2: WAD Library & Loadouts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single hardcoded "Play Freedoom" button with a real WAD library: import IWADs/PWADs/DEH patches (Files app, document picker, zips), stack them into named loadouts with load order, and play any loadout with per-loadout saves.

**Architecture:** Pure-Swift WAD parsing/storage layer (unit-tested, no engine dependency) feeding SwiftData models (`WADFile`, `Loadout`), orchestrated by `@MainActor` services (`LibraryService`, `ImportService`). SwiftUI launcher grows a loadout-grid home and a library tab; `EngineSession` gains an arguments-based entry built by `LoadoutArguments`. Bundled Freedoom registers as read-only library entries with two pre-seeded loadouts.

**Tech Stack:** Swift 6 / SwiftUI / SwiftData, CryptoKit (SHA-1), ZIPFoundation 0.9.19 (SPM), XCTest (new unit target) + XCUITest, XcodeGen, Xcode 26.2, iOS 26 simulator "iPhone 17 Pro".

**Spec:** `docs/superpowers/specs/2026-07-11-doom-ios-design.md` §4 (WAD library & data model), §5 (import errors). Plan 2 of 4.

## Global Constraints

- Deployment target **iOS 26.0**, build with Xcode 26.2, simulator "iPhone 17 Pro" (iOS 26.2).
- Commit messages: plain conventional, **no Co-Authored-By, no Claude/AI mention**.
- Never commit: `Vendor/`, `App/Resources/GameData/`, `App/Resources/woof.pk3`, `App/*.xcodeproj`, `App/Info.plist` (gitignored in Task 6), test WADs.
- Engine facts that bind this plan (established in Plan 1, do not "fix" them):
  - Save flag is **`-save <dir>`** (there is no `-savedir`). `-complevel` values are exactly **`vanilla, boom, mbf, mbf21`** (auto-detect when omitted).
  - `woof.pk3` stays at the bundle root; bundled IWADs live in the bundle's `GameData/` (folder reference must never be renamed to `Resources`).
  - `EngineSession` runs on the main thread and honors `BOOMBOX_AUTOQUIT_SECONDS`.
- No engine (`Engine/woof/`) changes are expected in this plan. If one becomes unavoidable, it must be minimal, `WOOF_IOS`-guarded, and documented in `Engine/WOOF_UPSTREAM.md`.
- Test WADs live at `~/Downloads/doom-test-wads/` (never committed): `scythe/SCYTHE.WAD` (vanilla), `sunlust/sunlust/sunlust.wad` (Boom, cl9), `eviternityii/Eviternity II.wad` (MBF21 — note the space in the filename), `myhouse/myhouse.wad` (loads as a plain map — its GZDoom half is the .pk3 we don't have; the runtime-error negative test is a wrong-IWAD pairing instead).
- All unit tests must run headless via `xcodebuild test` (no engine boot needed for the unit target).

## File Structure

```
App/Sources/
  BoomBoxApp.swift            (modify: ModelContainer + first-run seeding)
  ContentView.swift           (modify: becomes TabView host)
  EngineSession.swift         (modify: arguments-based API)
  WAD/WADParser.swift         (new: header/lump parsing, classification)
  WAD/WADStore.swift          (new: Documents/WADs file ops + SHA-1 dedupe)
  WAD/ZipExtractor.swift      (new: ZIPFoundation wrapper)
  Models/WADFile.swift        (new: SwiftData model)
  Models/Loadout.swift        (new: SwiftData model)
  Library/LibraryService.swift (new: queries, seeding, referential rules)
  Library/ImportService.swift  (new: picker/zip/loose-file import pipeline)
  Library/LoadoutArguments.swift (new: Loadout -> engine argv)
  UI/LoadoutGridView.swift    (new: home tab)
  UI/LoadoutEditorView.swift  (new: create/edit loadout)
  UI/LibraryView.swift        (new: imported-files tab)
App/Tests/                    (new unit-test target BoomBoxTests)
App/UITests/                  (extend smoke tests; add real-WAD matrix)
Scripts/provision-test-wads.sh (new: push ~/Downloads/doom-test-wads into simulator)
```

---

### Task 1: Unit-test target

**Files:**
- Modify: `App/project.yml`
- Create: `App/Tests/WADParserTests.swift` (placeholder test, replaced in Task 2)

**Interfaces:**
- Produces: `BoomBoxTests` unit-test target; `xcodebuild test` runs unit tests + existing UITests. All later tasks put unit tests in `App/Tests/`.

- [ ] **Step 1: Add the unit target and SPM package to project.yml**

In `App/project.yml`, add a top-level `packages:` block (after `options:`):

```yaml
packages:
  ZIPFoundation:
    url: https://github.com/weichsel/ZIPFoundation
    exactVersion: 0.9.19
```

Add to the `BoomBox` target's `dependencies:` list:

```yaml
      - package: ZIPFoundation
```

Add a new target alongside `BoomBoxUITests`:

```yaml
  BoomBoxTests:
    type: bundle.unit-test
    platform: iOS
    sources: [Tests]
    settings:
      base:
        GENERATE_INFOPLIST_FILE: true
    dependencies:
      - target: BoomBox
```

And add it to the scheme's test targets:

```yaml
    test:
      targets:
        - BoomBoxTests
        - BoomBoxUITests
```

- [ ] **Step 2: Write a placeholder test**

`App/Tests/WADParserTests.swift`:
```swift
import XCTest

final class WADParserTests: XCTestCase {
    func testScaffold() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 3: Regenerate and run**

```bash
cd App && xcodegen generate && cd ..
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxTests test
```
Expected: `TEST SUCCEEDED` (unit target only — fast, no engine boot).

- [ ] **Step 4: Commit**

```bash
git add App/project.yml App/Tests/WADParserTests.swift
git commit -m "test: add BoomBoxTests unit target and ZIPFoundation dependency"
```

---

### Task 2: WADParser

**Files:**
- Create: `App/Sources/WAD/WADParser.swift`
- Replace: `App/Tests/WADParserTests.swift`

**Interfaces:**
- Produces (exact API used by Tasks 3, 5, 6):
```swift
enum WADKind: String { case iwad = "IWAD", pwad = "PWAD" }
enum MapFormat { case episodic, mapXX, none }   // ExMy vs MAPxx
enum GameFamily: String { case doom1, doom2, unknown }
struct ParsedWAD { let kind: WADKind; let lumpNames: [String] }
enum WADParseError: Error, Equatable { case tooSmall, badMagic, corruptDirectory }
enum WADParser {
    static func parse(_ data: Data) throws -> ParsedWAD
    static func mapFormat(of lumpNames: [String]) -> MapFormat
    static func gameFamily(of lumpNames: [String]) -> GameFamily
}
```

- [ ] **Step 1: Write the failing tests**

Replace `App/Tests/WADParserTests.swift`:
```swift
import XCTest
@testable import BoomBox

/// Builds a syntactically valid WAD in memory.
/// Layout: 12-byte header | lump directory (16 bytes/lump, zero data).
func makeWAD(magic: String, lumps: [String]) -> Data {
    var data = Data(magic.utf8)                                // 0-3 magic
    data.append(contentsOf: withUnsafeBytes(of: Int32(lumps.count).littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: Int32(12).littleEndian, Array.init)) // dir right after header
    for name in lumps {
        data.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian, Array.init)) // filepos
        data.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian, Array.init)) // size
        var bytes = Array(name.utf8.prefix(8))
        bytes.append(contentsOf: Array(repeating: 0, count: 8 - bytes.count))
        data.append(contentsOf: bytes)
    }
    return data
}

final class WADParserTests: XCTestCase {
    func testParsesIWADMagic() throws {
        let wad = try WADParser.parse(makeWAD(magic: "IWAD", lumps: ["E1M1", "THINGS"]))
        XCTAssertEqual(wad.kind, .iwad)
        XCTAssertEqual(wad.lumpNames, ["E1M1", "THINGS"])
    }

    func testParsesPWADMagic() throws {
        let wad = try WADParser.parse(makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        XCTAssertEqual(wad.kind, .pwad)
    }

    func testRejectsBadMagic() {
        XCTAssertThrowsError(try WADParser.parse(makeWAD(magic: "JUNK", lumps: []))) {
            XCTAssertEqual($0 as? WADParseError, .badMagic)
        }
    }

    func testRejectsTruncatedFile() {
        XCTAssertThrowsError(try WADParser.parse(Data("IW".utf8))) {
            XCTAssertEqual($0 as? WADParseError, .tooSmall)
        }
    }

    func testRejectsDirectoryOutOfBounds() {
        var data = Data("PWAD".utf8)
        data.append(contentsOf: withUnsafeBytes(of: Int32(1000).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: Int32(999_999).littleEndian, Array.init))
        XCTAssertThrowsError(try WADParser.parse(data)) {
            XCTAssertEqual($0 as? WADParseError, .corruptDirectory)
        }
    }

    func testTextFileRenamedToWadIsRejected() {
        XCTAssertThrowsError(try WADParser.parse(Data("This is not a wad at all, just text".utf8))) {
            XCTAssertEqual($0 as? WADParseError, .badMagic)
        }
    }

    func testMapFormatEpisodic() {
        XCTAssertEqual(WADParser.mapFormat(of: ["E1M1", "THINGS", "E1M2"]), .episodic)
    }

    func testMapFormatMapXX() {
        XCTAssertEqual(WADParser.mapFormat(of: ["MAP01", "THINGS", "MAP32"]), .mapXX)
    }

    func testMapFormatNone() {
        XCTAssertEqual(WADParser.mapFormat(of: ["DEHACKED", "TEXTURE1"]), .none)
    }

    func testGameFamily() {
        XCTAssertEqual(WADParser.gameFamily(of: ["MAP01"]), .doom2)
        XCTAssertEqual(WADParser.gameFamily(of: ["E2M4"]), .doom1)
        XCTAssertEqual(WADParser.gameFamily(of: ["TEXTURE1"]), .unknown)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd App && xcodegen generate && cd ..
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxTests test
```
Expected: build FAILS with "cannot find 'WADParser' in scope".

- [ ] **Step 3: Implement**

`App/Sources/WAD/WADParser.swift`:
```swift
import Foundation

enum WADKind: String {
    case iwad = "IWAD"
    case pwad = "PWAD"
}

enum MapFormat { case episodic, mapXX, none }

enum GameFamily: String { case doom1, doom2, unknown }

struct ParsedWAD {
    let kind: WADKind
    let lumpNames: [String]
}

enum WADParseError: Error, Equatable {
    case tooSmall
    case badMagic
    case corruptDirectory
}

enum WADParser {
    /// WAD layout: magic(4) | numLumps(i32le) | dirOffset(i32le), then
    /// directory entries of filepos(4) | size(4) | name(8, NUL-padded).
    static func parse(_ data: Data) throws -> ParsedWAD {
        guard data.count >= 12 else { throw WADParseError.tooSmall }
        guard let kind = WADKind(rawValue: String(decoding: data.prefix(4), as: UTF8.self))
        else { throw WADParseError.badMagic }

        let numLumps = Int(readInt32LE(data, at: 4))
        let dirOffset = Int(readInt32LE(data, at: 8))
        guard numLumps >= 0, dirOffset >= 0,
              dirOffset + numLumps * 16 <= data.count
        else { throw WADParseError.corruptDirectory }

        var names: [String] = []
        names.reserveCapacity(numLumps)
        for i in 0..<numLumps {
            let entry = dirOffset + i * 16
            let nameBytes = data[(entry + 8)..<(entry + 16)].prefix { $0 != 0 }
            names.append(String(decoding: nameBytes, as: UTF8.self).uppercased())
        }
        return ParsedWAD(kind: kind, lumpNames: names)
    }

    static func mapFormat(of lumpNames: [String]) -> MapFormat {
        if lumpNames.contains(where: isMapXX) { return .mapXX }
        if lumpNames.contains(where: isEpisodic) { return .episodic }
        return .none
    }

    static func gameFamily(of lumpNames: [String]) -> GameFamily {
        switch mapFormat(of: lumpNames) {
        case .mapXX: .doom2
        case .episodic: .doom1
        case .none: .unknown
        }
    }

    private static func readInt32LE(_ data: Data, at offset: Int) -> Int32 {
        data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian
    }

    private static func isEpisodic(_ name: String) -> Bool {
        name.count == 4 && name.first == "E" && name[name.index(name.startIndex, offsetBy: 2)] == "M"
            && name.dropFirst().first!.isNumber && name.last!.isNumber
    }

    private static func isMapXX(_ name: String) -> Bool {
        name.count == 5 && name.hasPrefix("MAP") && name.dropFirst(3).allSatisfy(\.isNumber)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Same command as Step 2. Expected: `TEST SUCCEEDED`, all WADParserTests pass.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/WAD/WADParser.swift App/Tests/WADParserTests.swift
git commit -m "feat: WAD header/lump parsing with kind, map-format, and game-family detection"
```

---

### Task 3: WADStore (file storage + SHA-1 dedupe)

**Files:**
- Create: `App/Sources/WAD/WADStore.swift`
- Create: `App/Tests/WADStoreTests.swift`

**Interfaces:**
- Produces (used by Tasks 5, 6):
```swift
struct StoredWAD: Equatable { let filename: String; let sha1: String; let isDuplicate: Bool }
enum WADStoreError: Error, Equatable { case unreadable }
struct WADStore {
    let directory: URL                       // e.g. Documents/WADs
    init(directory: URL)
    static var `default`: WADStore           // Documents/WADs
    func store(fileAt source: URL, preferredName: String) throws -> StoredWAD
    func url(forFilename filename: String) -> URL
    func delete(filename: String) throws
    static func sha1(of data: Data) -> String
}
```
- Semantics: `store` hashes the source, and if a file with the same SHA-1 already exists in `directory`, returns that existing entry with `isDuplicate: true` (no copy). Otherwise copies in, resolving filename collisions (different content, same name) by suffixing ` (2)`, ` (3)`, ….

- [ ] **Step 1: Write the failing tests**

`App/Tests/WADStoreTests.swift`:
```swift
import XCTest
@testable import BoomBox

final class WADStoreTests: XCTestCase {
    var tmp: URL!
    var store: WADStore!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = WADStore(directory: tmp.appendingPathComponent("WADs", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func writeSource(_ name: String, _ contents: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testStoresFileAndComputesSHA1() throws {
        let src = try writeSource("a.wad", "hello")
        let stored = try store.store(fileAt: src, preferredName: "a.wad")
        XCTAssertEqual(stored.filename, "a.wad")
        XCTAssertFalse(stored.isDuplicate)
        // shasum -a1 of "hello"
        XCTAssertEqual(stored.sha1, "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(forFilename: "a.wad").path))
    }

    func testDuplicateContentIsDeduplicated() throws {
        _ = try store.store(fileAt: writeSource("a.wad", "same"), preferredName: "a.wad")
        let dup = try store.store(fileAt: writeSource("b.wad", "same"), preferredName: "b.wad")
        XCTAssertTrue(dup.isDuplicate)
        XCTAssertEqual(dup.filename, "a.wad")   // points at the existing file
    }

    func testNameCollisionWithDifferentContentGetsSuffix() throws {
        _ = try store.store(fileAt: writeSource("x1.wad", "one"), preferredName: "map.wad")
        let second = try store.store(fileAt: writeSource("x2.wad", "two"), preferredName: "map.wad")
        XCTAssertEqual(second.filename, "map (2).wad")
        XCTAssertFalse(second.isDuplicate)
    }

    func testFilenameWithSpacesSurvives() throws {
        let src = try writeSource("Eviternity II.wad", "big")
        let stored = try store.store(fileAt: src, preferredName: "Eviternity II.wad")
        XCTAssertEqual(stored.filename, "Eviternity II.wad")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(forFilename: stored.filename).path))
    }

    func testDelete() throws {
        _ = try store.store(fileAt: writeSource("a.wad", "gone"), preferredName: "a.wad")
        try store.delete(filename: "a.wad")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(forFilename: "a.wad").path))
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxTests test
```
Expected: build FAILS with "cannot find 'WADStore' in scope".

- [ ] **Step 3: Implement**

`App/Sources/WAD/WADStore.swift`:
```swift
import CryptoKit
import Foundation

struct StoredWAD: Equatable {
    let filename: String
    let sha1: String
    let isDuplicate: Bool
}

enum WADStoreError: Error, Equatable {
    case unreadable
}

/// Owns the on-disk WAD directory. Knows nothing about SwiftData; the
/// library layer keeps metadata and refers to files by `filename`.
struct WADStore {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    static var `default`: WADStore {
        WADStore(directory: URL.documentsDirectory.appendingPathComponent("WADs", isDirectory: true))
    }

    func store(fileAt source: URL, preferredName: String) throws -> StoredWAD {
        guard let data = try? Data(contentsOf: source) else { throw WADStoreError.unreadable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sha1 = Self.sha1(of: data)

        // Dedupe by content hash against everything already in the store.
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in existing {
            if let other = try? Data(contentsOf: url), Self.sha1(of: other) == sha1 {
                return StoredWAD(filename: url.lastPathComponent, sha1: sha1, isDuplicate: true)
            }
        }

        // Resolve name collisions (same name, different content).
        var candidate = preferredName
        var counter = 2
        while FileManager.default.fileExists(atPath: url(forFilename: candidate).path) {
            let base = (preferredName as NSString).deletingPathExtension
            let ext = (preferredName as NSString).pathExtension
            candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            counter += 1
        }
        try data.write(to: url(forFilename: candidate))
        return StoredWAD(filename: candidate, sha1: sha1, isDuplicate: false)
    }

    func url(forFilename filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    func delete(filename: String) throws {
        try FileManager.default.removeItem(at: url(forFilename: filename))
    }

    static func sha1(of data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
```

Note: hash-scan-on-import re-reads existing files; fine at library scale (spec's dedupe requirement, and imports are user-paced). The metadata layer (Task 5) also short-circuits by stored hash before reaching this scan.

- [ ] **Step 4: Run to verify pass**

Same command as Step 2. Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/WAD/WADStore.swift App/Tests/WADStoreTests.swift
git commit -m "feat: content-addressed WAD file store with SHA-1 dedupe"
```

---

### Task 4: ZipExtractor

**Files:**
- Create: `App/Sources/WAD/ZipExtractor.swift`
- Create: `App/Tests/ZipExtractorTests.swift`

**Interfaces:**
- Produces (used by Task 6):
```swift
struct ExtractedFile { let name: String; let url: URL }  // name = basename inside zip
enum ZipExtractor {
    /// Extracts .wad/.deh/.bex entries (any nesting depth) to a fresh temp
    /// dir. Ignores everything else. Caller owns cleanup of the returned dir.
    static func extractGameFiles(from zipURL: URL) throws -> (dir: URL, files: [ExtractedFile])
}
```

- [ ] **Step 1: Write the failing tests**

`App/Tests/ZipExtractorTests.swift`:
```swift
import XCTest
import ZIPFoundation
@testable import BoomBox

final class ZipExtractorTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Builds a zip containing entries at the given paths.
    private func makeZip(entries: [String: String]) throws -> URL {
        let zipURL = tmp.appendingPathComponent("\(UUID().uuidString).zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        for (path, contents) in entries {
            let data = Data(contents.utf8)
            try archive.addEntry(with: path, type: .file,
                                 uncompressedSize: Int64(data.count),
                                 provider: { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            })
        }
        return zipURL
    }

    func testExtractsWadAndDehIgnoresJunk() throws {
        let zip = try makeZip(entries: [
            "cool.wad": "PWAD....",
            "patch.deh": "Patch File for DeHackEd",
            "readme.txt": "ignore me",
        ])
        let result = try ZipExtractor.extractGameFiles(from: zip)
        defer { try? FileManager.default.removeItem(at: result.dir) }
        XCTAssertEqual(Set(result.files.map(\.name)), ["cool.wad", "patch.deh"])
    }

    func testExtractsFromNestedDirectories() throws {
        // Mirrors sunlust.zip's real layout: sunlust/sunlust.wad
        let zip = try makeZip(entries: ["sunlust/sunlust.wad": "PWAD....",
                                        "sunlust/sunlust.txt": "notes"])
        let result = try ZipExtractor.extractGameFiles(from: zip)
        defer { try? FileManager.default.removeItem(at: result.dir) }
        XCTAssertEqual(result.files.map(\.name), ["sunlust.wad"])
    }

    func testZipWithNoGameFilesReturnsEmpty() throws {
        let zip = try makeZip(entries: ["readme.txt": "nothing here"])
        let result = try ZipExtractor.extractGameFiles(from: zip)
        defer { try? FileManager.default.removeItem(at: result.dir) }
        XCTAssertTrue(result.files.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxTests test
```
Expected: build FAILS with "cannot find 'ZipExtractor' in scope".

- [ ] **Step 3: Implement**

`App/Sources/WAD/ZipExtractor.swift`:
```swift
import Foundation
import ZIPFoundation

struct ExtractedFile {
    let name: String
    let url: URL
}

enum ZipExtractor {
    private static let gameExtensions: Set<String> = ["wad", "deh", "bex"]

    static func extractGameFiles(from zipURL: URL) throws -> (dir: URL, files: [ExtractedFile]) {
        let archive = try Archive(url: zipURL, accessMode: .read)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wad-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var files: [ExtractedFile] = []
        for entry in archive where entry.type == .file {
            let basename = (entry.path as NSString).lastPathComponent
            let ext = (basename as NSString).pathExtension.lowercased()
            guard gameExtensions.contains(ext) else { continue }
            let dest = dir.appendingPathComponent(basename)
            _ = try archive.extract(entry, to: dest)
            files.append(ExtractedFile(name: basename, url: dest))
        }
        return (dir, files)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Same command as Step 2. Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/WAD/ZipExtractor.swift App/Tests/ZipExtractorTests.swift
git commit -m "feat: extract wad/deh/bex entries from zip archives"
```

---

### Task 5: SwiftData models + LibraryService

**Files:**
- Create: `App/Sources/Models/WADFile.swift`
- Create: `App/Sources/Models/Loadout.swift`
- Create: `App/Sources/Library/LibraryService.swift`
- Create: `App/Tests/LibraryServiceTests.swift`

**Interfaces:**
- Produces (used by Tasks 6–9):
```swift
@Model final class WADFile {
    var id: UUID
    var filename: String        // in WADStore dir, or bundle GameData if isBundled
    var displayName: String
    var kindRaw: String         // WADKind.rawValue or "DEH"
    var sha1: String
    var gameFamilyRaw: String   // GameFamily.rawValue
    var isBundled: Bool
    var importDate: Date
}
@Model final class Loadout {
    var id: UUID
    var name: String
    var iwadID: UUID
    var pwadIDs: [UUID]         // ordered
    var dehIDs: [UUID]          // ordered
    var complevel: String?      // nil = engine auto-detect; else vanilla|boom|mbf|mbf21
    var lastPlayed: Date?
    var createdAt: Date
}
enum LibraryError: Error, Equatable { case wadReferencedByLoadouts([String]) }
@MainActor final class LibraryService {
    init(context: ModelContext, store: WADStore)
    func seedBundledContentIfNeeded() throws     // Freedoom entries + 2 loadouts, idempotent
    func allWADs() throws -> [WADFile]
    func allLoadouts() throws -> [Loadout]       // most recently played first
    func wad(id: UUID) throws -> WADFile?
    func findWAD(sha1: String) throws -> WADFile?
    func registerImported(filename: String, sha1: String, kind: String, family: String) throws -> WADFile
    func createLoadout(name: String, iwadID: UUID, pwadIDs: [UUID], dehIDs: [UUID]) throws -> Loadout
    func deleteLoadout(_ loadout: Loadout, deleteSaves: Bool) throws
    func loadoutsReferencing(wadID: UUID) throws -> [Loadout]
    func deleteWAD(_ wad: WADFile, force: Bool) throws  // throws .wadReferencedByLoadouts unless force
    func fileURL(for wad: WADFile) -> URL       // bundle GameData vs WADStore dir
    static func savesDirectory(forLoadoutID id: UUID) -> URL  // Documents/Saves/<uuid>
}
```

- [ ] **Step 1: Write the failing tests**

`App/Tests/LibraryServiceTests.swift`:
```swift
import SwiftData
import XCTest
@testable import BoomBox

@MainActor
final class LibraryServiceTests: XCTestCase {
    var service: LibraryService!
    var context: ModelContext!
    var tmp: URL!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, configurations: config)
        context = ModelContext(container)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        service = LibraryService(context: context, store: WADStore(directory: tmp))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testSeedCreatesFreedoomEntriesAndLoadoutsOnce() throws {
        try service.seedBundledContentIfNeeded()
        try service.seedBundledContentIfNeeded()   // idempotent
        let wads = try service.allWADs()
        XCTAssertEqual(wads.filter(\.isBundled).map(\.filename).sorted(),
                       ["freedoom1.wad", "freedoom2.wad"])
        let loadouts = try service.allLoadouts()
        XCTAssertEqual(loadouts.map(\.name).sorted(),
                       ["Freedoom Phase 1", "Freedoom Phase 2"])
    }

    func testRegisterAndFindBySHA1() throws {
        let wad = try service.registerImported(filename: "sunlust.wad", sha1: "abc123",
                                               kind: "PWAD", family: "doom2")
        XCTAssertEqual(try service.findWAD(sha1: "abc123")?.id, wad.id)
        XCTAssertNil(try service.findWAD(sha1: "nope"))
    }

    func testDeleteWADReferencedByLoadoutThrowsUnlessForced() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i1",
                                                kind: "IWAD", family: "doom2")
        let pwad = try service.registerImported(filename: "sunlust.wad", sha1: "p1",
                                                kind: "PWAD", family: "doom2")
        let loadout = try service.createLoadout(name: "Sunlust", iwadID: iwad.id,
                                                pwadIDs: [pwad.id], dehIDs: [])
        XCTAssertThrowsError(try service.deleteWAD(pwad, force: false)) {
            XCTAssertEqual($0 as? LibraryError, .wadReferencedByLoadouts(["Sunlust"]))
        }
        try service.deleteWAD(pwad, force: true)
        XCTAssertNil(try service.wad(id: pwad.id))
        _ = loadout
    }

    func testDeleteLoadoutRemovesSavesWhenAsked() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i2",
                                                kind: "IWAD", family: "doom2")
        let loadout = try service.createLoadout(name: "X", iwadID: iwad.id, pwadIDs: [], dehIDs: [])
        let saves = LibraryService.savesDirectory(forLoadoutID: loadout.id)
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        try Data("save".utf8).write(to: saves.appendingPathComponent("savegame0.dsg"))
        try service.deleteLoadout(loadout, deleteSaves: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: saves.path))
        XCTAssertTrue(try service.allLoadouts().isEmpty)
    }

    func testLoadoutOrderingPreserved() throws {
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "i3",
                                                kind: "IWAD", family: "doom2")
        let a = try service.registerImported(filename: "a.wad", sha1: "a", kind: "PWAD", family: "doom2")
        let b = try service.registerImported(filename: "b.wad", sha1: "b", kind: "PWAD", family: "doom2")
        let loadout = try service.createLoadout(name: "Ordered", iwadID: iwad.id,
                                                pwadIDs: [b.id, a.id], dehIDs: [])
        XCTAssertEqual(loadout.pwadIDs, [b.id, a.id])
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxTests test
```
Expected: build FAILS with "cannot find type 'WADFile' in scope".

- [ ] **Step 3: Implement the models**

`App/Sources/Models/WADFile.swift`:
```swift
import Foundation
import SwiftData

@Model
final class WADFile {
    @Attribute(.unique) var id: UUID
    var filename: String
    var displayName: String
    var kindRaw: String
    var sha1: String
    var gameFamilyRaw: String
    var isBundled: Bool
    var importDate: Date

    init(id: UUID = UUID(), filename: String, displayName: String, kindRaw: String,
         sha1: String, gameFamilyRaw: String, isBundled: Bool = false,
         importDate: Date = .now) {
        self.id = id
        self.filename = filename
        self.displayName = displayName
        self.kindRaw = kindRaw
        self.sha1 = sha1
        self.gameFamilyRaw = gameFamilyRaw
        self.isBundled = isBundled
        self.importDate = importDate
    }
}
```

`App/Sources/Models/Loadout.swift`:
```swift
import Foundation
import SwiftData

@Model
final class Loadout {
    @Attribute(.unique) var id: UUID
    var name: String
    var iwadID: UUID
    var pwadIDs: [UUID]
    var dehIDs: [UUID]
    var complevel: String?
    var lastPlayed: Date?
    var createdAt: Date

    init(id: UUID = UUID(), name: String, iwadID: UUID, pwadIDs: [UUID] = [],
         dehIDs: [UUID] = [], complevel: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.iwadID = iwadID
        self.pwadIDs = pwadIDs
        self.dehIDs = dehIDs
        self.complevel = complevel
        self.lastPlayed = nil
        self.createdAt = createdAt
    }
}
```

- [ ] **Step 4: Implement LibraryService**

`App/Sources/Library/LibraryService.swift`:
```swift
import Foundation
import SwiftData

enum LibraryError: Error, Equatable {
    case wadReferencedByLoadouts([String])
}

@MainActor
final class LibraryService {
    private let context: ModelContext
    private let store: WADStore

    init(context: ModelContext, store: WADStore) {
        self.context = context
        self.store = store
    }

    // MARK: Seeding

    /// Registers the bundled Freedoom IWADs (read-only, live in the bundle's
    /// GameData/) and creates one loadout per phase. Safe to call every launch.
    func seedBundledContentIfNeeded() throws {
        let bundled: [(file: String, title: String, family: GameFamily)] = [
            ("freedoom1.wad", "Freedoom Phase 1", .doom1),
            ("freedoom2.wad", "Freedoom Phase 2", .doom2),
        ]
        for entry in bundled {
            if try wadByFilename(entry.file, bundled: true) != nil { continue }
            let wad = WADFile(filename: entry.file, displayName: entry.title,
                              kindRaw: WADKind.iwad.rawValue, sha1: "bundled:\(entry.file)",
                              gameFamilyRaw: entry.family.rawValue, isBundled: true)
            context.insert(wad)
            context.insert(Loadout(name: entry.title, iwadID: wad.id))
        }
        try context.save()
    }

    // MARK: Queries

    func allWADs() throws -> [WADFile] {
        try context.fetch(FetchDescriptor<WADFile>(
            sortBy: [SortDescriptor(\.importDate, order: .reverse)]))
    }

    func allLoadouts() throws -> [Loadout] {
        try context.fetch(FetchDescriptor<Loadout>()).sorted {
            ($0.lastPlayed ?? $0.createdAt) > ($1.lastPlayed ?? $1.createdAt)
        }
    }

    func wad(id: UUID) throws -> WADFile? {
        var descriptor = FetchDescriptor<WADFile>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func findWAD(sha1: String) throws -> WADFile? {
        var descriptor = FetchDescriptor<WADFile>(predicate: #Predicate { $0.sha1 == sha1 })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func wadByFilename(_ filename: String, bundled: Bool) throws -> WADFile? {
        var descriptor = FetchDescriptor<WADFile>(
            predicate: #Predicate { $0.filename == filename && $0.isBundled == bundled })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: Mutations

    @discardableResult
    func registerImported(filename: String, sha1: String, kind: String,
                          family: String) throws -> WADFile {
        let wad = WADFile(filename: filename,
                          displayName: (filename as NSString).deletingPathExtension,
                          kindRaw: kind, sha1: sha1, gameFamilyRaw: family)
        context.insert(wad)
        try context.save()
        return wad
    }

    @discardableResult
    func createLoadout(name: String, iwadID: UUID, pwadIDs: [UUID],
                       dehIDs: [UUID]) throws -> Loadout {
        let loadout = Loadout(name: name, iwadID: iwadID, pwadIDs: pwadIDs, dehIDs: dehIDs)
        context.insert(loadout)
        try context.save()
        return loadout
    }

    func loadoutsReferencing(wadID: UUID) throws -> [Loadout] {
        try context.fetch(FetchDescriptor<Loadout>()).filter {
            $0.iwadID == wadID || $0.pwadIDs.contains(wadID) || $0.dehIDs.contains(wadID)
        }
    }

    func deleteWAD(_ wad: WADFile, force: Bool) throws {
        let referencing = try loadoutsReferencing(wadID: wad.id)
        if !referencing.isEmpty && !force {
            throw LibraryError.wadReferencedByLoadouts(referencing.map(\.name))
        }
        if !wad.isBundled {
            try? store.delete(filename: wad.filename)
        }
        context.delete(wad)
        try context.save()
    }

    func deleteLoadout(_ loadout: Loadout, deleteSaves: Bool) throws {
        if deleteSaves {
            try? FileManager.default.removeItem(
                at: Self.savesDirectory(forLoadoutID: loadout.id))
        }
        context.delete(loadout)
        try context.save()
    }

    // MARK: Paths

    func fileURL(for wad: WADFile) -> URL {
        if wad.isBundled {
            return Bundle.main.resourceURL!
                .appendingPathComponent("GameData", isDirectory: true)
                .appendingPathComponent(wad.filename)
        }
        return store.url(forFilename: wad.filename)
    }

    static func savesDirectory(forLoadoutID id: UUID) -> URL {
        URL.documentsDirectory
            .appendingPathComponent("Saves", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }
}
```

- [ ] **Step 5: Run to verify pass**

Same command as Step 2. Expected: `TEST SUCCEEDED`. (Note: bundled Freedoom entries deliberately use a `bundled:` pseudo-hash — hashing 30MB files at every launch buys nothing since the bundle is immutable.)

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Models App/Sources/Library/LibraryService.swift App/Tests/LibraryServiceTests.swift
git commit -m "feat: SwiftData WAD library with bundled-Freedoom seeding and referential rules"
```

---

### Task 6: ImportService + Files-app/Info.plist wiring

**Files:**
- Create: `App/Sources/Library/ImportService.swift`
- Create: `App/Tests/ImportServiceTests.swift`
- Modify: `App/project.yml` (Info.plist strategy: back to a real plist via `info:`)
- Modify: `.gitignore` (add `App/Info.plist`)

**Interfaces:**
- Consumes: `WADParser`, `WADStore`, `ZipExtractor`, `LibraryService`.
- Produces (used by Tasks 8, 9):
```swift
struct ImportOutcome: Equatable {
    var imported: [String]      // display names
    var duplicates: [String]
    var rejected: [String: String]  // filename -> reason
}
@MainActor final class ImportService {
    init(library: LibraryService, store: WADStore)
    func importFiles(at urls: [URL]) -> ImportOutcome     // .wad/.deh/.bex/.zip
    func adoptLooseFiles() -> ImportOutcome  // scans Documents root (Files-app drops)
}
```

**Info.plist strategy note (reverses commit 77c19c5, deliberately):** Files-app
visibility (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`) has
`INFOPLIST_KEY_` equivalents, but document-type registration
(`CFBundleDocumentTypes` + `UTImportedTypeDeclarations`, needed for
"Share → Open in BoomBox" on .wad files) is nested-dictionary plist content
with **no** build-setting mapping. So the app target goes back to XcodeGen's
`info:` directive (which writes `App/Info.plist` at `xcodegen generate` time,
same lifecycle as the .xcodeproj) and the file gets gitignored. Keep all
current `INFOPLIST_KEY_*` values by moving them into `info: properties:`.

- [ ] **Step 1: Write the failing tests**

`App/Tests/ImportServiceTests.swift`:
```swift
import SwiftData
import XCTest
@testable import BoomBox

@MainActor
final class ImportServiceTests: XCTestCase {
    var importer: ImportService!
    var library: LibraryService!
    var tmp: URL!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, configurations: config)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = WADStore(directory: tmp.appendingPathComponent("WADs", isDirectory: true))
        library = LibraryService(context: ModelContext(container), store: store)
        importer = ImportService(library: library, store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testImportsValidPWAD() throws {
        let url = try write("sunlust.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let outcome = importer.importFiles(at: [url])
        XCTAssertEqual(outcome.imported, ["sunlust"])
        XCTAssertEqual(try library.allWADs().first?.kindRaw, "PWAD")
        XCTAssertEqual(try library.allWADs().first?.gameFamilyRaw, "doom2")
    }

    func testRejectsInvalidWadWithReason() throws {
        let url = try write("fake.wad", Data("not a wad".utf8))
        let outcome = importer.importFiles(at: [url])
        XCTAssertTrue(outcome.imported.isEmpty)
        XCTAssertNotNil(outcome.rejected["fake.wad"])
        XCTAssertTrue(try library.allWADs().isEmpty)
    }

    func testDuplicateImportReported() throws {
        let data = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        _ = importer.importFiles(at: [try write("a.wad", data)])
        let outcome = importer.importFiles(at: [try write("b.wad", data)])
        XCTAssertEqual(outcome.duplicates.count, 1)
        XCTAssertEqual(try library.allWADs().count, 1)
    }

    func testImportsDEHByExtension() throws {
        let url = try write("tweaks.deh", Data("Patch File for DeHackEd 3.0".utf8))
        let outcome = importer.importFiles(at: [url])
        XCTAssertEqual(outcome.imported, ["tweaks"])
        XCTAssertEqual(try library.allWADs().first?.kindRaw, "DEH")
    }

    func testImportsWadsOutOfZip() throws {
        // Build a zip with a nested wad + junk, like real downloads.
        let zipURL = tmp.appendingPathComponent("dl.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let wadData = makeWAD(magic: "PWAD", lumps: ["E1M1"])
        try archive.addEntry(with: "release/map.wad", type: .file,
                             uncompressedSize: Int64(wadData.count),
                             provider: { pos, size in
            wadData.subdata(in: Int(pos)..<Int(pos) + size)
        })
        let outcome = importer.importFiles(at: [zipURL])
        XCTAssertEqual(outcome.imported, ["map"])
        XCTAssertEqual(try library.allWADs().first?.gameFamilyRaw, "doom1")
    }
}

import ZIPFoundation
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxTests test
```
Expected: build FAILS with "cannot find 'ImportService' in scope".

- [ ] **Step 3: Implement**

`App/Sources/Library/ImportService.swift`:
```swift
import Foundation

struct ImportOutcome: Equatable {
    var imported: [String] = []
    var duplicates: [String] = []
    var rejected: [String: String] = [:]
}

@MainActor
final class ImportService {
    private let library: LibraryService
    private let store: WADStore

    init(library: LibraryService, store: WADStore) {
        self.library = library
        self.store = store
    }

    /// Imports picker/Files-app URLs: .wad validated+classified, .deh/.bex
    /// taken by extension, .zip recursed into. Security-scoped access is
    /// handled here so callers can pass fileImporter URLs directly.
    func importFiles(at urls: [URL]) -> ImportOutcome {
        var outcome = ImportOutcome()
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            importOne(url: url, into: &outcome)
        }
        return outcome
    }

    /// Adopts files users dropped into Documents via the Files app
    /// (UIFileSharingEnabled exposes it). Call on launch/foreground.
    func adoptLooseFiles() -> ImportOutcome {
        var outcome = ImportOutcome()
        let docs = URL.documentsDirectory
        let candidates = ((try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: [.isRegularFileKey])) ?? [])
            .filter { ["wad", "deh", "bex", "zip"].contains($0.pathExtension.lowercased()) }
        for url in candidates {
            importOne(url: url, into: &outcome)
            // Adopted or rejected either way, remove the loose original so
            // the scan doesn't re-report it forever (imports are copies).
            try? FileManager.default.removeItem(at: url)
        }
        return outcome
    }

    private func importOne(url: URL, into outcome: inout ImportOutcome) {
        let name = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "zip":
            do {
                let extraction = try ZipExtractor.extractGameFiles(from: url)
                defer { try? FileManager.default.removeItem(at: extraction.dir) }
                if extraction.files.isEmpty {
                    outcome.rejected[name] = "No WAD or DEH files inside the zip."
                    return
                }
                for file in extraction.files {
                    importOne(url: file.url, into: &outcome)
                }
            } catch {
                outcome.rejected[name] = "Could not read zip archive."
            }
        case "deh", "bex":
            storeAndRegister(url: url, name: name, kind: "DEH",
                             family: GameFamily.unknown.rawValue, into: &outcome)
        case "wad":
            do {
                guard let data = try? Data(contentsOf: url) else {
                    outcome.rejected[name] = "File could not be read."
                    return
                }
                let parsed = try WADParser.parse(data)
                storeAndRegister(url: url, name: name, kind: parsed.kind.rawValue,
                                 family: WADParser.gameFamily(of: parsed.lumpNames).rawValue,
                                 into: &outcome)
            } catch WADParseError.badMagic {
                outcome.rejected[name] = "Not a WAD file (bad header magic)."
            } catch WADParseError.tooSmall {
                outcome.rejected[name] = "File is truncated (smaller than a WAD header)."
            } catch {
                outcome.rejected[name] = "WAD directory is corrupt."
            }
        default:
            outcome.rejected[name] = "Unsupported file type."
        }
    }

    private func storeAndRegister(url: URL, name: String, kind: String,
                                  family: String, into outcome: inout ImportOutcome) {
        do {
            let stored = try store.store(fileAt: url, preferredName: name)
            if stored.isDuplicate || (try? library.findWAD(sha1: stored.sha1)) != nil {
                if (try? library.findWAD(sha1: stored.sha1)) == nil {
                    // File existed on disk but not in the DB (e.g. prior
                    // failed import) — register it now instead of dropping it.
                    try library.registerImported(filename: stored.filename,
                                                 sha1: stored.sha1, kind: kind, family: family)
                    outcome.imported.append((stored.filename as NSString).deletingPathExtension)
                } else {
                    outcome.duplicates.append((name as NSString).deletingPathExtension)
                }
                return
            }
            try library.registerImported(filename: stored.filename, sha1: stored.sha1,
                                         kind: kind, family: family)
            outcome.imported.append((stored.filename as NSString).deletingPathExtension)
        } catch {
            outcome.rejected[name] = "Could not copy file into the library."
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Same command as Step 2. Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Switch the app target to a real Info.plist**

In `App/project.yml`, on the `BoomBox` target: delete `GENERATE_INFOPLIST_FILE: true` and every `INFOPLIST_KEY_*` line (keep `CURRENT_PROJECT_VERSION`/`MARKETING_VERSION`), and add an `info:` block:

```yaml
    info:
      path: Info.plist
      properties:
        UILaunchScreen: {}
        UIStatusBarHidden: true
        UIRequiresFullScreen: true
        UIApplicationSupportsIndirectInputEvents: true
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        UIFileSharingEnabled: true
        LSSupportsOpeningDocumentsInPlace: true
        CFBundleDocumentTypes:
          - CFBundleTypeName: Doom WAD
            LSHandlerRank: Owner
            LSItemContentTypes: [com.tylervick.boombox.wad]
          - CFBundleTypeName: DeHackEd Patch
            LSHandlerRank: Owner
            LSItemContentTypes: [com.tylervick.boombox.deh]
          - CFBundleTypeName: Zip Archive
            LSHandlerRank: Alternate
            LSItemContentTypes: [public.zip-archive]
        UTImportedTypeDeclarations:
          - UTTypeIdentifier: com.tylervick.boombox.wad
            UTTypeDescription: Doom WAD
            UTTypeConformsTo: [public.data]
            UTTypeTagSpecification:
              public.filename-extension: [wad]
          - UTTypeIdentifier: com.tylervick.boombox.deh
            UTTypeDescription: DeHackEd Patch
            UTTypeConformsTo: [public.data]
            UTTypeTagSpecification:
              public.filename-extension: [deh, bex]
```

Add to `.gitignore` (generated at `xcodegen generate` time, like the .xcodeproj):
```gitignore
App/Info.plist
```

Regenerate + verify the synthesized/loaded plist and the smoke gate still pass:
```bash
cd App && xcodegen generate && cd ..
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
APP=$(find ~/Library/Developer/Xcode/DerivedData -path '*BoomBox*/Build/Products/Debug-iphonesimulator/BoomBox.app' | head -1)
plutil -p "$APP/Info.plist" | grep -E "UIFileSharingEnabled|LSSupportsOpeningDocumentsInPlace|CFBundleDocumentTypes" -A2
```
Expected: both booleans `1`, document types present. Then run the full test suite (`xcodebuild ... test`) — expected `TEST SUCCEEDED` (UITests still green proves the plist swap broke nothing).

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Library/ImportService.swift App/Tests/ImportServiceTests.swift \
        App/project.yml .gitignore
git commit -m "feat: import pipeline (picker/zip/loose files) and Files-app document types"
```

---

### Task 7: LoadoutArguments + EngineSession refactor

**Files:**
- Create: `App/Sources/Library/LoadoutArguments.swift`
- Create: `App/Tests/LoadoutArgumentsTests.swift`
- Modify: `App/Sources/EngineSession.swift`
- Modify: `App/Sources/ContentView.swift` (temporary shim so it still builds; replaced in Task 8)

**Interfaces:**
- Consumes: `Loadout`, `WADFile`, `LibraryService.fileURL(for:)`, `LibraryService.savesDirectory(forLoadoutID:)`.
- Produces:
```swift
enum LoadoutArguments {
    /// argv for a loadout: woof -iwad X [-file A B ...] [-deh C ...] -save DIR [-complevel L]
    /// Creates the saves directory. resolve maps a WADFile ID to its URL.
    static func build(loadout: Loadout, resolve: (UUID) throws -> URL) throws -> [String]
}
enum LoadoutArgumentsError: Error, Equatable { case missingWAD(UUID) }
// EngineSession gains:
@MainActor enum EngineSession {
    @discardableResult static func play(arguments: [String]) -> Int32  // full argv incl. "woof"
}
```

- [ ] **Step 1: Write the failing tests**

`App/Tests/LoadoutArgumentsTests.swift`:
```swift
import XCTest
@testable import BoomBox

final class LoadoutArgumentsTests: XCTestCase {
    private func resolver(_ map: [UUID: String]) -> (UUID) throws -> URL {
        { id in
            guard let path = map[id] else { throw LoadoutArgumentsError.missingWAD(id) }
            return URL(fileURLWithPath: path)
        }
    }

    func testIWADOnly() throws {
        let loadout = Loadout(name: "F1", iwadID: UUID())
        let args = try LoadoutArguments.build(
            loadout: loadout, resolve: resolver([loadout.iwadID: "/gd/freedoom1.wad"]))
        XCTAssertEqual(Array(args.prefix(3)), ["woof", "-iwad", "/gd/freedoom1.wad"])
        XCTAssertEqual(args[3], "-save")
        XCTAssertTrue(args[4].hasSuffix("/Saves/\(loadout.id.uuidString)"))
        XCTAssertFalse(args.contains("-file"))
        XCTAssertFalse(args.contains("-complevel"))
    }

    func testFullStackKeepsPWADOrderAndSpaces() throws {
        let iwad = UUID(), a = UUID(), b = UUID(), deh = UUID()
        let loadout = Loadout(name: "EvII", iwadID: iwad, pwadIDs: [b, a], dehIDs: [deh])
        loadout.complevel = "mbf21"
        let args = try LoadoutArguments.build(loadout: loadout, resolve: resolver([
            iwad: "/gd/freedoom2.wad",
            a: "/wads/a.wad",
            b: "/wads/Eviternity II.wad",
            deh: "/wads/fix.deh",
        ]))
        let fileIdx = args.firstIndex(of: "-file")!
        XCTAssertEqual(args[fileIdx + 1], "/wads/Eviternity II.wad") // order preserved, space intact
        XCTAssertEqual(args[fileIdx + 2], "/wads/a.wad")
        let dehIdx = args.firstIndex(of: "-deh")!
        XCTAssertEqual(args[dehIdx + 1], "/wads/fix.deh")
        XCTAssertEqual(args.last!, "mbf21")
        XCTAssertEqual(args[args.count - 2], "-complevel")
    }

    func testMissingWADThrows() {
        let loadout = Loadout(name: "broken", iwadID: UUID())
        XCTAssertThrowsError(try LoadoutArguments.build(loadout: loadout,
                                                        resolve: resolver([:]))) {
            XCTAssertEqual($0 as? LoadoutArgumentsError, .missingWAD(loadout.iwadID))
        }
    }

    func testSavesDirectoryIsCreated() throws {
        let loadout = Loadout(name: "F1", iwadID: UUID())
        _ = try LoadoutArguments.build(
            loadout: loadout, resolve: resolver([loadout.iwadID: "/gd/f1.wad"]))
        let saves = LibraryService.savesDirectory(forLoadoutID: loadout.id)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: saves.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        try? FileManager.default.removeItem(at: saves)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxTests test
```
Expected: build FAILS with "cannot find 'LoadoutArguments' in scope".

- [ ] **Step 3: Implement LoadoutArguments**

`App/Sources/Library/LoadoutArguments.swift`:
```swift
import Foundation

enum LoadoutArgumentsError: Error, Equatable {
    case missingWAD(UUID)
}

enum LoadoutArguments {
    static func build(loadout: Loadout, resolve: (UUID) throws -> URL) throws -> [String] {
        var args = ["woof", "-iwad", try resolve(loadout.iwadID).path]

        if !loadout.pwadIDs.isEmpty {
            args.append("-file")
            for id in loadout.pwadIDs {
                args.append(try resolve(id).path)
            }
        }
        if !loadout.dehIDs.isEmpty {
            args.append("-deh")
            for id in loadout.dehIDs {
                args.append(try resolve(id).path)
            }
        }

        let saves = LibraryService.savesDirectory(forLoadoutID: loadout.id)
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        args += ["-save", saves.path]

        if let complevel = loadout.complevel {
            args += ["-complevel", complevel]   // vanilla|boom|mbf|mbf21 (Woof-validated)
        }
        return args
    }
}
```

- [ ] **Step 4: Refactor EngineSession**

Replace the body of `App/Sources/EngineSession.swift`:
```swift
import Foundation
import WoofEngine

/// Runs Woof! engine sessions. The engine takes over the screen with its own
/// SDL window; this call blocks the main thread until the user quits (SDL
/// pumps UIKit events internally, so the app stays responsive to the system).
@MainActor
enum EngineSession {
    private(set) static var isRunning = false

    /// Boots the engine with a full argv (starting with "woof") and returns
    /// the engine exit code. Build argv with LoadoutArguments.
    @discardableResult
    static func play(arguments: [String]) -> Int32 {
        precondition(!isRunning, "engine session already running")
        precondition(arguments.first == "woof", "argv[0] must be the program name")

        // If the host asked for an auto-quit (UI testing), schedule it on a
        // background thread; WoofIOS_RequestQuit is thread-safe.
        if let secondsString = ProcessInfo.processInfo
            .environment["BOOMBOX_AUTOQUIT_SECONDS"],
            let seconds = Double(secondsString)
        {
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: seconds)
                WoofIOS_RequestQuit()
            }
        }

        isRunning = true
        defer { isRunning = false }

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        defer { argv.forEach { free($0) } }
        return WoofIOS_Run(Int32(arguments.count), &argv)
    }
}
```

Update `App/Sources/ContentView.swift`'s button action to keep the build green
(Task 8 replaces this view wholesale):
```swift
            Button("Play Freedoom Phase 1") {
                lastExitCode = nil
                let iwad = Bundle.main.resourceURL!
                    .appendingPathComponent("GameData/freedoom1.wad")
                let saves = URL.documentsDirectory.appendingPathComponent("Saves/freedoom1")
                try? FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
                lastExitCode = EngineSession.play(
                    arguments: ["woof", "-iwad", iwad.path, "-save", saves.path])
            }
```

- [ ] **Step 5: Run the FULL suite (unit + engine smoke)**

```bash
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
Expected: `TEST SUCCEEDED` — LoadoutArguments unit tests pass AND the two-cycle engine smoke gate still passes through the refactored `play(arguments:)`.

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Library/LoadoutArguments.swift App/Tests/LoadoutArgumentsTests.swift \
        App/Sources/EngineSession.swift App/Sources/ContentView.swift
git commit -m "feat: loadout-to-argv builder and arguments-based engine session"
```

---

### Task 8: Launcher UI (loadout grid, editor, library tab)

**Files:**
- Modify: `App/Sources/BoomBoxApp.swift`
- Modify: `App/Sources/ContentView.swift`
- Create: `App/Sources/UI/LoadoutGridView.swift`
- Create: `App/Sources/UI/LoadoutEditorView.swift`
- Create: `App/Sources/UI/LibraryView.swift`
- Modify: `App/UITests/EngineSmokeTests.swift` (drive the new UI)

**Interfaces:**
- Consumes: everything from Tasks 2–7.
- Produces accessibility identifiers the UITests (this task + Task 9) rely on:
  - Loadout tile: `loadout-<name>` (e.g. `loadout-Freedoom Phase 1`); the seeded Phase 1 tile ALSO keeps id `playFreedoom1` for smoke-test continuity.
  - `engineExitLabel` (unchanged semantics: cleared at session start, shows "Engine exited: N").
  - Library tab button: `libraryTab`; play tab: `playTab`; import button: `importButton`; new-loadout button: `newLoadoutButton`; editor fields: `loadoutNameField`, `iwadPicker`, `addPWADButton-<display>`, `saveLoadoutButton`.

- [ ] **Step 1: App bootstrap (ModelContainer + seeding + loose-file adoption)**

Replace `App/Sources/BoomBoxApp.swift`:
```swift
import SwiftData
import SwiftUI

@main
struct BoomBoxApp: App {
    let container: ModelContainer
    let library: LibraryService
    let importer: ImportService

    init() {
        do {
            container = try ModelContainer(for: WADFile.self, Loadout.self)
            let context = ModelContext(container)
            let store = WADStore.default
            library = LibraryService(context: context, store: store)
            importer = ImportService(library: library, store: store)
            try library.seedBundledContentIfNeeded()
            _ = importer.adoptLooseFiles()
        } catch {
            fatalError("SwiftData container failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(library: library, importer: importer)
        }
        .modelContainer(container)
    }
}
```

- [ ] **Step 2: ContentView becomes the tab host**

Replace `App/Sources/ContentView.swift`:
```swift
import SwiftUI

struct ContentView: View {
    let library: LibraryService
    let importer: ImportService
    @State private var lastExitCode: Int32?

    var body: some View {
        TabView {
            Tab("Play", systemImage: "play.circle.fill") {
                LoadoutGridView(library: library, lastExitCode: $lastExitCode)
            }
            .accessibilityIdentifier("playTab")

            Tab("Library", systemImage: "books.vertical") {
                LibraryView(library: library, importer: importer)
            }
            .accessibilityIdentifier("libraryTab")
        }
        .overlay(alignment: .bottom) {
            if let code = lastExitCode {
                Text("Engine exited: \(code)")
                    .font(.footnote.monospaced())
                    .padding(6)
                    .background(.thinMaterial, in: Capsule())
                    .accessibilityIdentifier("engineExitLabel")
                    .padding(.bottom, 60)
            }
        }
    }
}
```

- [ ] **Step 3: LoadoutGridView**

`App/Sources/UI/LoadoutGridView.swift`:
```swift
import SwiftUI

struct LoadoutGridView: View {
    let library: LibraryService
    @Binding var lastExitCode: Int32?
    @State private var loadouts: [Loadout] = []
    @State private var editorLoadout: Loadout?
    @State private var showNewEditor = false

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(loadouts, id: \.id) { loadout in
                        tile(for: loadout)
                    }
                }
                .padding()
            }
            .navigationTitle("BoomBox")
            .toolbar {
                Button {
                    showNewEditor = true
                } label: {
                    Label("New Loadout", systemImage: "plus")
                }
                .accessibilityIdentifier("newLoadoutButton")
            }
            .sheet(isPresented: $showNewEditor, onDismiss: refresh) {
                LoadoutEditorView(library: library, existing: nil)
            }
            .sheet(item: $editorLoadout, onDismiss: refresh) { loadout in
                LoadoutEditorView(library: library, existing: loadout)
            }
            .onAppear(perform: refresh)
        }
    }

    private func tile(for loadout: Loadout) -> some View {
        Button {
            play(loadout)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.title)
                Text(loadout.name).font(.headline).lineLimit(2)
                Text(subtitle(for: loadout))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(loadout.name == "Freedoom Phase 1"
                                 ? "playFreedoom1" : "loadout-\(loadout.name)")
        .contextMenu {
            Button("Edit") { editorLoadout = loadout }
            Button("Delete Loadout & Saves", role: .destructive) {
                try? library.deleteLoadout(loadout, deleteSaves: true)
                refresh()
            }
            Button("Delete Loadout, Keep Saves", role: .destructive) {
                try? library.deleteLoadout(loadout, deleteSaves: false)
                refresh()
            }
        }
    }

    private func subtitle(for loadout: Loadout) -> String {
        let pwads = loadout.pwadIDs.compactMap { try? library.wad(id: $0)?.displayName }
        return pwads.isEmpty ? "Base game" : pwads.joined(separator: " + ")
    }

    private func play(_ loadout: Loadout) {
        lastExitCode = nil
        do {
            let args = try LoadoutArguments.build(loadout: loadout) { id in
                guard let wad = try library.wad(id: id) else {
                    throw LoadoutArgumentsError.missingWAD(id)
                }
                return library.fileURL(for: wad)
            }
            loadout.lastPlayed = .now
            lastExitCode = EngineSession.play(arguments: args)
        } catch {
            lastExitCode = -101   // arg-building failure (missing WAD)
        }
        refresh()
    }

    private func refresh() {
        loadouts = (try? library.allLoadouts()) ?? []
    }
}
```

- [ ] **Step 4: LoadoutEditorView**

`App/Sources/UI/LoadoutEditorView.swift`:
```swift
import SwiftUI

struct LoadoutEditorView: View {
    let library: LibraryService
    let existing: Loadout?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var iwadID: UUID?
    @State private var pwadIDs: [UUID] = []
    @State private var dehIDs: [UUID] = []
    @State private var complevel: String?

    private var iwads: [WADFile] { (try? library.allWADs())?.filter { $0.kindRaw == "IWAD" } ?? [] }
    private var pwads: [WADFile] { (try? library.allWADs())?.filter { $0.kindRaw == "PWAD" } ?? [] }
    private var dehs: [WADFile] { (try? library.allWADs())?.filter { $0.kindRaw == "DEH" } ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Loadout name", text: $name)
                        .accessibilityIdentifier("loadoutNameField")
                }
                Section("Base game (IWAD)") {
                    Picker("IWAD", selection: $iwadID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(iwads, id: \.id) { wad in
                            Text(wad.displayName).tag(UUID?.some(wad.id))
                        }
                    }
                    .accessibilityIdentifier("iwadPicker")
                }
                Section("Mods (PWADs, load order top → bottom)") {
                    ForEach(pwadIDs, id: \.self) { id in
                        Text((try? library.wad(id: id))?.displayName ?? "?")
                    }
                    .onMove { pwadIDs.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { pwadIDs.remove(atOffsets: $0) }
                    Menu("Add PWAD") {
                        ForEach(pwads.filter { !pwadIDs.contains($0.id) }, id: \.id) { wad in
                            Button(wad.displayName) { pwadIDs.append(wad.id) }
                                .accessibilityIdentifier("addPWADButton-\(wad.displayName)")
                        }
                    }
                }
                Section("DeHackEd patches") {
                    ForEach(dehIDs, id: \.self) { id in
                        Text((try? library.wad(id: id))?.displayName ?? "?")
                    }
                    .onDelete { dehIDs.remove(atOffsets: $0) }
                    Menu("Add patch") {
                        ForEach(dehs.filter { !dehIDs.contains($0.id) }, id: \.id) { deh in
                            Button(deh.displayName) { dehIDs.append(deh.id) }
                        }
                    }
                }
                Section("Compatibility") {
                    Picker("Complevel", selection: $complevel) {
                        Text("Auto (recommended)").tag(String?.none)
                        ForEach(["vanilla", "boom", "mbf", "mbf21"], id: \.self) {
                            Text($0).tag(String?.some($0))
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Loadout" : "Edit Loadout")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || iwadID == nil)
                        .accessibilityIdentifier("saveLoadoutButton")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .environment(\.editMode, .constant(.active))
            .onAppear(perform: populate)
        }
    }

    private func populate() {
        guard let existing else { return }
        name = existing.name
        iwadID = existing.iwadID
        pwadIDs = existing.pwadIDs
        dehIDs = existing.dehIDs
        complevel = existing.complevel
    }

    private func save() {
        guard let iwadID else { return }
        if let existing {
            existing.name = name
            existing.iwadID = iwadID
            existing.pwadIDs = pwadIDs
            existing.dehIDs = dehIDs
            existing.complevel = complevel
        } else {
            let loadout = try? library.createLoadout(name: name, iwadID: iwadID,
                                                     pwadIDs: pwadIDs, dehIDs: dehIDs)
            loadout?.complevel = complevel
        }
        dismiss()
    }
}
```

- [ ] **Step 5: LibraryView**

`App/Sources/UI/LibraryView.swift`:
```swift
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    let library: LibraryService
    let importer: ImportService

    @State private var wads: [WADFile] = []
    @State private var showImporter = false
    @State private var lastOutcome: ImportOutcome?
    @State private var deleteBlocked: [String] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(wads, id: \.id) { wad in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(wad.displayName)
                            Text(wad.isBundled ? "Bundled" : wad.filename)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(wad.kindRaw)
                            .font(.caption.bold())
                            .padding(4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .deleteDisabled(wad.isBundled)
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("Library")
            .toolbar {
                Button {
                    showImporter = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("importButton")
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: importTypes,
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    lastOutcome = importer.importFiles(at: urls)
                    refresh()
                }
            }
            .alert("Import complete", isPresented: outcomeAlertBinding, presenting: lastOutcome) { _ in
                Button("OK") { lastOutcome = nil }
            } message: { outcome in
                Text(summary(of: outcome))
            }
            .alert("WAD in use", isPresented: deleteBlockedBinding) {
                Button("OK") { deleteBlocked = [] }
            } message: {
                Text("Used by: \(deleteBlocked.joined(separator: ", ")). Remove it from those loadouts first.")
            }
            .onAppear(perform: refresh)
        }
    }

    private var importTypes: [UTType] {
        var types: [UTType] = [.zip]
        if let wad = UTType(filenameExtension: "wad") { types.append(wad) }
        if let deh = UTType(filenameExtension: "deh") { types.append(deh) }
        if let bex = UTType(filenameExtension: "bex") { types.append(bex) }
        return types
    }

    private var outcomeAlertBinding: Binding<Bool> {
        Binding(get: { lastOutcome != nil }, set: { if !$0 { lastOutcome = nil } })
    }

    private var deleteBlockedBinding: Binding<Bool> {
        Binding(get: { !deleteBlocked.isEmpty }, set: { if !$0 { deleteBlocked = [] } })
    }

    private func summary(of outcome: ImportOutcome) -> String {
        var lines: [String] = []
        if !outcome.imported.isEmpty { lines.append("Imported: \(outcome.imported.joined(separator: ", "))") }
        if !outcome.duplicates.isEmpty { lines.append("Already in library: \(outcome.duplicates.joined(separator: ", "))") }
        for (file, reason) in outcome.rejected { lines.append("\(file): \(reason)") }
        return lines.isEmpty ? "Nothing imported." : lines.joined(separator: "\n")
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let wad = wads[index]
            do {
                try library.deleteWAD(wad, force: false)
            } catch LibraryError.wadReferencedByLoadouts(let names) {
                deleteBlocked = names
            } catch {}
        }
        refresh()
    }

    private func refresh() {
        wads = (try? library.allWADs()) ?? []
    }
}
```

- [ ] **Step 6: Update the smoke test for the new UI**

In `App/UITests/EngineSmokeTests.swift`, the `playFreedoom1` button is now the
seeded Phase 1 tile — same identifier, so only the assertion text of any
launcher-specific waits needs checking. Run the suite; if the tile needs an
extra tap to dismiss a first-run alert (loose-file adoption outcome alert only
fires when files were adopted — not in a clean simulator), no change needed.

- [ ] **Step 7: Run the FULL suite**

```bash
cd App && xcodegen generate && cd ..
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
Expected: `TEST SUCCEEDED` — unit tests + two-cycle smoke gate through the new grid UI.

- [ ] **Step 8: Commit**

```bash
git add App/Sources App/UITests
git commit -m "feat: loadout-grid launcher, loadout editor, and library tab"
```

---

### Task 9: Real-WAD verification matrix on the simulator

**Files:**
- Create: `Scripts/provision-test-wads.sh`
- Create: `App/UITests/RealWADTests.swift`

**Interfaces:**
- Consumes: the full app; test WADs from `~/Downloads/doom-test-wads/`.
- Produces: a repeatable on-simulator verification that Boom/MBF21-tier WADs actually run, and that a wrong-IWAD pairing fails soft.

- [ ] **Step 1: Write the provisioning script**

`Scripts/provision-test-wads.sh`:
```bash
#!/bin/bash
# Copies local test WADs into the booted simulator's BoomBox Documents dir
# so the app's loose-file adoption imports them on next launch.
# Usage: Scripts/provision-test-wads.sh [device-name]
set -euo pipefail
DEVICE="${1:-iPhone 17 Pro}"
SRC="$HOME/Downloads/doom-test-wads"
BUNDLE_ID="com.tylervick.BoomBox"

xcrun simctl boot "$DEVICE" 2>/dev/null || true
CONTAINER="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)"
DOCS="$CONTAINER/Documents"
mkdir -p "$DOCS"

cp "$SRC/scythe/SCYTHE.WAD" "$DOCS/"
cp "$SRC/sunlust/sunlust/sunlust.wad" "$DOCS/"
cp "$SRC/eviternityii/Eviternity II.wad" "$DOCS/"
ls -la "$DOCS"
echo "Provisioned. Launch the app to adopt the files."
```

```bash
chmod +x Scripts/provision-test-wads.sh
```
Note: the app must be installed before `get_app_container` works — build/install first (Step 3).

- [ ] **Step 2: Write the real-WAD UITest matrix**

`App/UITests/RealWADTests.swift`:
```swift
import XCTest

/// Requires Scripts/provision-test-wads.sh to have been run against the
/// booted simulator AFTER the app was installed. Each test creates a loadout
/// through the real UI, plays it with autoquit, and asserts a full-length
/// session (or, for the negative case, a fast engine-error exit that the app
/// survives).
final class RealWADTests: XCTestCase {

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BOOMBOX_AUTOQUIT_SECONDS"] = "10"
        app.launch()
        // Dismiss the loose-file adoption alert if it fired this launch.
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }
        return app
    }

    /// Creates (if needed) and plays a loadout; asserts session length.
    private func runLoadout(app: XCUIApplication, name: String, iwad: String,
                            pwad: String?, expectFullSession: Bool,
                            file: StaticString = #filePath, line: UInt = #line) {
        let tile = app.buttons["loadout-\(name)"]
        if !tile.exists {
            app.buttons["newLoadoutButton"].tap()
            let nameField = app.textFields["loadoutNameField"]
            XCTAssertTrue(nameField.waitForExistence(timeout: 5), file: file, line: line)
            nameField.tap()
            nameField.typeText(name)
            app.buttons["iwadPicker"].tap()
            app.buttons[iwad].tap()
            if let pwad {
                app.buttons["Add PWAD"].tap()
                app.buttons["addPWADButton-\(pwad)"].tap()
            }
            app.buttons["saveLoadoutButton"].tap()
            XCTAssertTrue(tile.waitForExistence(timeout: 5),
                          "loadout tile missing after save", file: file, line: line)
        }

        let exitLabel = app.staticTexts["engineExitLabel"]
        let start = Date()
        tile.tap()
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90),
                      "engine never returned", file: file, line: line)
        let elapsed = Date().timeIntervalSince(start)
        if expectFullSession {
            XCTAssertEqual(exitLabel.label, "Engine exited: 0", file: file, line: line)
            XCTAssertGreaterThanOrEqual(elapsed, 9.0,
                "session died before its autoquit window", file: file, line: line)
        } else {
            XCTAssertNotEqual(exitLabel.label, "Engine exited: 0",
                "wrong-IWAD pairing unexpectedly booted", file: file, line: line)
            // App survived the engine error — launcher still interactive:
            XCTAssertTrue(app.buttons["playTab"].isHittable, file: file, line: line)
        }
    }

    @MainActor
    func testVanillaScytheOnFreedoom2() {
        let app = launchApp()
        runLoadout(app: app, name: "Scythe", iwad: "Freedoom Phase 2",
                   pwad: "SCYTHE", expectFullSession: true)
    }

    @MainActor
    func testBoomSunlustOnFreedoom2() {
        let app = launchApp()
        runLoadout(app: app, name: "Sunlust", iwad: "Freedoom Phase 2",
                   pwad: "sunlust", expectFullSession: true)
    }

    @MainActor
    func testMBF21EviternityIIOnFreedoom2() {
        let app = launchApp()
        runLoadout(app: app, name: "Eviternity II", iwad: "Freedoom Phase 2",
                   pwad: "Eviternity II", expectFullSession: true)
    }

    /// Negative: a MAPxx megawad on a Doom-1-format IWAD. The engine must
    /// fail with an error exit, and the app must survive to the launcher.
    @MainActor
    func testWrongIWADPairingFailsSoft() {
        let app = launchApp()
        runLoadout(app: app, name: "Mismatch", iwad: "Freedoom Phase 1",
                   pwad: "sunlust", expectFullSession: false)
    }
}
```

- [ ] **Step 3: Build, install, provision, run the matrix**

```bash
cd App && xcodegen generate && cd ..
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
xcrun simctl install "iPhone 17 Pro" \
  "$(find ~/Library/Developer/Xcode/DerivedData -path '*BoomBox*/Build/Products/Debug-iphonesimulator/BoomBox.app' | head -1)"
xcrun simctl launch "iPhone 17 Pro" com.tylervick.BoomBox && sleep 5
xcrun simctl terminate "iPhone 17 Pro" com.tylervick.BoomBox
Scripts/provision-test-wads.sh
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxUITests/RealWADTests test
```
Expected: `TEST SUCCEEDED`, all four matrix tests green. **Also capture visual
evidence:** during (or after) the run, `xcrun simctl io "iPhone 17 Pro"
screenshot /tmp/evII.png` while Eviternity II is playing and Read the png —
it must show Eviternity II's distinctive first map, not Freedoom content
(this is the human check that PWAD content actually loaded over the IWAD).
Behavior notes: sunlust/Eviternity II on Freedoom 2 show Freedoom's episode
art in menus — expected; content correctness is judged in-map. The wrong-IWAD
case exits fast with a nonzero code (missing MAPxx/texture lumps).

- [ ] **Step 4: Also confirm the standing smoke suite still passes**

```bash
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxTests -only-testing:BoomBoxUITests/EngineSmokeTests test
```
Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Scripts/provision-test-wads.sh App/UITests/RealWADTests.swift
git commit -m "test: real-WAD matrix (vanilla/Boom/MBF21 + wrong-IWAD negative) on simulator"
```

Note: `RealWADTests` needs provisioned WADs, so it will fail on a machine
without `~/Downloads/doom-test-wads/` — that's acceptable for now and gets a
README note in Task 10 (CI story is a later plan's concern).

---

### Task 10: Docs wrap-up

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document the library features and test-WAD workflow**

Add to `README.md` after the Building section:

```markdown
## WAD library

Import WADs three ways: the in-app Import button, "Share → BoomBox" from
another app, or drop files into the app's folder in the Files app (they're
adopted on next launch). IWADs, PWADs, `.deh`/`.bex` patches, and zips
containing any of those all work. Build **loadouts** (one IWAD + ordered
PWADs/patches); each loadout keeps its own save games. Freedoom Phase 1+2
are bundled and pre-wired as loadouts.

### Real-WAD test matrix

`App/UITests/RealWADTests.swift` verifies vanilla/Boom/MBF21 content plus a
wrong-IWAD negative case against real community WADs. It expects the files
in `~/Downloads/doom-test-wads/` (see the script header) provisioned via
`Scripts/provision-test-wads.sh` after installing the app on the simulator;
without them, only that test class fails.
```

- [ ] **Step 2: Reconcile docs with any execution deviations**

Compare the final state of every file this plan touched against what the
README/spec claim (import paths, save layout, Info.plist strategy). Fix any
drift found. Then full suite one last time:
```bash
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxTests -only-testing:BoomBoxUITests/EngineSmokeTests test
```
Expected: `TEST SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: WAD library usage and real-WAD test matrix"
```

---

## Plan self-review notes

- **Spec §4 coverage:** Files-app visibility + document picker + "Open in" types (Task 6), zip auto-extract (Tasks 4/6), header validation + SHA-1 dedupe + specific rejection messages (Tasks 2/3/6), IWAD/PWAD classification + base-game hint as suggestion-not-block (Tasks 2/5/8 — the editor never blocks pairing; the hint surfaces via detected-family metadata), `WADFile`/`Loadout` models with ordered PWADs/DEH + optional complevel (Task 5, values verified against `g_game.c`: vanilla/boom/mbf/mbf21), per-loadout saves via `-save` keyed by loadout ID (Tasks 5/7), referential rules (delete-loadout offers save deletion; delete-WAD warns, Tasks 5/8), bundled Freedoom read-only/undeletable + pre-created loadouts (Tasks 5/8), loadout grid home + library tab + editor with drag reorder (Task 8).
- **Consciously deferred (spec'd but later-plan):** engine `I_Error` *text* surfaced in an alert (Plan 4 — this plan asserts nonzero-exit + app-survives via the wrong-IWAD test; exit-code plumbing exists since Plan 1); "tap a lone PWAD → offer new loadout with detected IWAD" shortcut (Plan 4 polish; core pairing flows exist in the editor).
- **Type consistency check:** `WADKind.rawValue`/`kindRaw` strings ("IWAD"/"PWAD"/"DEH") consistent across Tasks 2/5/6/8; `LibraryService.savesDirectory(forLoadoutID:)` used by both `LoadoutArguments` (Task 7) and delete-saves (Task 5); accessibility ids in Task 8 Step 3–5 match Task 9's queries; `ImportOutcome` shape matches between Tasks 6 and 8.
- **Grounded facts:** current `EngineSession`/`ContentView`/`project.yml` read before writing; `-complevel` values verified in vendored source; sunlust.zip's nested layout mirrored in Task 4's test; "Eviternity II.wad" space-in-filename exercised in Tasks 3 and 9.
