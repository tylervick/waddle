# Play & Library Rework — Plan C: Title Art (TITLEPIC) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render each playable tile with the WAD's own title-screen art — decode the `TITLEPIC` lump (DOOM picture format, or a PNG lump) with the `PLAYPAL` palette — and fall back to generated art when absent.

**Architecture:** Four layers, decoupled and testable bottom-up: (1) `WADLumpIndex` reads a WAD's directory to byte offsets without loading the whole file; (2) `DoomGraphics` purely decodes `PLAYPAL` → RGBA palette and the picture (patch) format → an RGBA bitmap; (3) `WADArtwork` orchestrates — finds `TITLEPIC`/`PLAYPAL` across candidate WADs, decodes to a `CGImage` (or a PNG lump via ImageIO), and disk-caches by content hash, off the main thread; (4) `TitleArtView` async-loads the art into the tile/detail placeholders with a generated-art fallback.

**Tech Stack:** Swift 6, SwiftUI, CoreGraphics + ImageIO (CGImage/PNG), XCTest, XcodeGen. Builds on Plans A + B. Spec: `docs/superpowers/specs/2026-07-23-play-library-rework-design.md` ("Title art").

## Global Constraints

- **Commits:** SIGNED (1Password SSH); retry on hang (`for i in $(seq 10); do git commit ... && break || sleep 15; done`); never unsigned.
- **Commit/PR text:** NO Claude/AI attribution, NO `Co-Authored-By`, no AI-tooling mention.
- **NEVER commit `App/WADdle.xcodeproj`** — gitignored/generated (`.gitignore` `App/*.xcodeproj`). Commit only `.swift`/doc files; every checkout runs `mise run generate`.
- **New source/test FILES require regen:** after adding any file under `App/Sources` or `App/Tests`, run `mise run generate` before building (XcodeGen globs those dirs). Modifying existing files needs no regen.
- **Test commands:**
  - Unit: `xcodebuild -project App/WADdle.xcodeproj -scheme WADdle -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WADdleTests/<Class>[/<method>] test`
  - Build all: `xcodebuild -project App/WADdle.xcodeproj -scheme WADdle -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build-for-testing`
- **Performance/safety (from spec):** decode **lazily and off the main thread**; never block launch or import (large WADs — Eviternity II ~293 MB — must not be fully loaded; read only the directory + the two lumps via `FileHandle` seeks). Cache decoded thumbnails to disk keyed by content hash.
- **DOOM binary formats (authoritative, little-endian):**
  - **WAD directory:** `magic(4) | numLumps(i32) | dirOffset(i32)`, then `numLumps` entries of `filepos(i32) | size(i32) | name(8, NUL-padded ASCII)`.
  - **PLAYPAL:** ≥768 bytes; palette 0 = the first 256 RGB triples (`r,g,b` bytes). (14 palettes total; only palette 0 is used.)
  - **Picture (patch) format:** header `width(u16) | height(u16) | leftoffset(i16) | topoffset(i16)`, then `width` × `columnofs(u32)` (byte offset from lump start to each column). Each column is a run of posts: `topdelta(u8)` (0xFF ends the column) `| length(u8) | unused(u8) | length×pixel(u8, palette index) | unused(u8)`. Pixels land at rows `[topdelta, topdelta+length)`. (Assumes ≤254-tall patches — `TITLEPIC` is 200 tall; tall-patch running-topdelta is out of scope.)
  - **PNG lump:** some ports store `TITLEPIC` as PNG — detect the 8-byte signature `89 50 4E 47 0D 0A 1A 0A` at the lump start and decode via ImageIO instead of the picture decoder.

---

## File Structure

**Created:**
- `App/Sources/WAD/WADLumpIndex.swift` — parse a WAD directory to `[name → (offset, size)]`; read a named lump's bytes via `FileHandle` without loading the whole file.
- `App/Sources/WAD/DoomGraphics.swift` — pure decoders: `PLAYPAL` → RGBA palette; picture (patch) lump + palette → RGBA `Bitmap`.
- `App/Sources/WAD/WADArtwork.swift` — orchestrator: candidate WAD URLs → `CGImage` (picture or PNG), disk-cached by key, off-main-thread; plus a `candidates(for:library:)` resolver.
- `App/Sources/UI/TitleArtView.swift` — async art loader + `GeneratedArtView` fallback.

**Modified:**
- `App/Sources/UI/PlayableTileView.swift` — replace the placeholder `RoundedRectangle` fill with `TitleArtView`.
- `App/Sources/UI/PlayableDetailView.swift` — replace the header placeholder art with `TitleArtView`.

**Tests (new files → regen):**
- `App/Tests/WADLumpIndexTests.swift`, `App/Tests/DoomGraphicsTests.swift`, `App/Tests/WADArtworkTests.swift`.

---

## Task 1: `WADLumpIndex` — directory offsets + lump reads

Locates lumps by byte offset (which `WADParser` discards) and reads a single lump's bytes without loading the whole WAD.

**Files:**
- Create: `App/Sources/WAD/WADLumpIndex.swift`
- Test: `App/Tests/WADLumpIndexTests.swift` (new — needs `mise run generate`)

**Interfaces:**
- Produces:
  - `struct WADLumpIndex { struct Entry: Equatable { let name: String; let offset: Int; let size: Int }; let entries: [Entry]; init(wad data: Data) throws; func offsetSize(of name: String) -> (offset: Int, size: Int)? }`
  - `static WADLumpIndex.read(from url: URL) throws -> WADLumpIndex` — reads only the 12-byte header + the directory region via `FileHandle`.
  - `static WADLumpIndex.lumpData(_ name: String, at url: URL, index: WADLumpIndex) throws -> Data?` — seeks to the lump offset and reads `size` bytes.
  - `enum WADLumpIndexError: Error { case tooSmall, badMagic, corruptDirectory, unreadable }`

- [ ] **Step 1: Write the failing test**

Create `App/Tests/WADLumpIndexTests.swift`:

```swift
import XCTest
@testable import WADdle

final class WADLumpIndexTests: XCTestCase {
    // Builds a minimal WAD: header + one lump "DATA" (bytes) + directory.
    private func makeWAD(lumpName: String, lump: [UInt8]) -> Data {
        var d = Data()
        func i32(_ v: Int) -> Data { withUnsafeBytes(of: Int32(v).littleEndian) { Data($0) } }
        let headerSize = 12
        let lumpOffset = headerSize
        let dirOffset = headerSize + lump.count
        d.append(contentsOf: Array("IWAD".utf8))       // magic
        d.append(i32(1))                                // numLumps
        d.append(i32(dirOffset))                        // dirOffset
        d.append(contentsOf: lump)                      // lump bytes at offset 12
        d.append(i32(lumpOffset))                       // dir entry: filepos
        d.append(i32(lump.count))                       // dir entry: size
        var name8 = Array(lumpName.utf8); name8 += Array(repeating: 0, count: 8 - name8.count)
        d.append(contentsOf: name8)                     // dir entry: name (8, NUL-padded)
        return d
    }

    func testFindsLumpOffsetAndSize() throws {
        let wad = makeWAD(lumpName: "DATA", lump: [0xAA, 0xBB, 0xCC])
        let index = try WADLumpIndex(wad: wad)
        let os = index.offsetSize(of: "DATA")
        XCTAssertEqual(os?.offset, 12)
        XCTAssertEqual(os?.size, 3)
        XCTAssertNil(index.offsetSize(of: "NOPE"))
    }

    func testLumpNameIsUppercasedAndLookupCaseInsensitive() throws {
        let wad = makeWAD(lumpName: "TITLEPIC", lump: [1, 2])
        let index = try WADLumpIndex(wad: wad)
        XCTAssertNotNil(index.offsetSize(of: "titlepic"))
    }

    func testReadsLumpBytesFromFileHandle() throws {
        let wad = makeWAD(lumpName: "DATA", lump: [0xAA, 0xBB, 0xCC])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wad")
        try wad.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let index = try WADLumpIndex.read(from: url)
        XCTAssertEqual(try WADLumpIndex.lumpData("DATA", at: url, index: index).map(Array.init), [0xAA, 0xBB, 0xCC])
    }

    func testRejectsBadMagic() {
        var d = Data("XXXX".utf8); d.append(Data(repeating: 0, count: 8))
        XCTAssertThrowsError(try WADLumpIndex(wad: d))
    }
}
```

- [ ] **Step 2: Run to verify fail** — `mise run generate` then `xcodebuild ... -only-testing:WADdleTests/WADLumpIndexTests test`. Expected: FAIL (no `WADLumpIndex`).

- [ ] **Step 3: Implement**

Create `App/Sources/WAD/WADLumpIndex.swift`:

```swift
import Foundation

enum WADLumpIndexError: Error, Equatable { case tooSmall, badMagic, corruptDirectory, unreadable }

/// Reads a WAD's directory to byte offsets (which `WADParser` discards) so a
/// specific lump can be located and read without loading the whole file.
struct WADLumpIndex {
    struct Entry: Equatable { let name: String; let offset: Int; let size: Int }
    let entries: [Entry]

    /// Parses from a Data holding at least the header + directory region.
    init(wad data: Data) throws {
        guard data.count >= 12 else { throw WADLumpIndexError.tooSmall }
        let base = data.startIndex
        let magic = String(decoding: data[base..<base+4], as: UTF8.self)
        guard magic == "IWAD" || magic == "PWAD" else { throw WADLumpIndexError.badMagic }
        let numLumps = Int(Self.i32(data, at: base + 4))
        let dirOffset = Int(Self.i32(data, at: base + 8))
        guard numLumps >= 0, dirOffset >= 0, dirOffset + numLumps * 16 <= data.count else {
            throw WADLumpIndexError.corruptDirectory
        }
        var entries: [Entry] = []; entries.reserveCapacity(numLumps)
        for i in 0..<numLumps {
            let e = base + dirOffset + i * 16
            let offset = Int(Self.i32(data, at: e))
            let size = Int(Self.i32(data, at: e + 4))
            let nameBytes = data[(e + 8)..<(e + 16)].prefix { $0 != 0 }
            entries.append(Entry(name: String(decoding: nameBytes, as: UTF8.self).uppercased(),
                                 offset: offset, size: size))
        }
        self.entries = entries
    }

    /// First lump matching `name` (case-insensitive).
    func offsetSize(of name: String) -> (offset: Int, size: Int)? {
        let upper = name.uppercased()
        guard let e = entries.first(where: { $0.name == upper }) else { return nil }
        return (e.offset, e.size)
    }

    private static func i32(_ data: Data, at offset: Int) -> Int32 {
        data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian
    }

    /// Reads only the header + directory region via FileHandle (no full-file load).
    static func read(from url: URL) throws -> WADLumpIndex {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw WADLumpIndexError.unreadable }
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 12), header.count == 12 else {
            throw WADLumpIndexError.tooSmall
        }
        let magic = String(decoding: header[0..<4], as: UTF8.self)
        guard magic == "IWAD" || magic == "PWAD" else { throw WADLumpIndexError.badMagic }
        let numLumps = Int(i32(header, at: 0 + 4))
        let dirOffset = Int(i32(header, at: 0 + 8))
        guard numLumps >= 0, dirOffset >= 0 else { throw WADLumpIndexError.corruptDirectory }
        try handle.seek(toOffset: UInt64(dirOffset))
        let dir = (try handle.read(upToCount: numLumps * 16)) ?? Data()
        guard dir.count == numLumps * 16 else { throw WADLumpIndexError.corruptDirectory }
        // Re-parse from a synthetic buffer: reuse the Data initializer by
        // fabricating a minimal header pointing at the directory we just read.
        var buf = Data(magic.utf8)
        buf.append(withUnsafeBytes(of: Int32(numLumps).littleEndian) { Data($0) })
        buf.append(withUnsafeBytes(of: Int32(12).littleEndian) { Data($0) })  // dir now at offset 12
        buf.append(dir)
        return try WADLumpIndex(wad: buf)   // offsets inside `dir` still point into the real file
    }

    /// Reads a single lump's bytes from the file at its recorded offset/size.
    static func lumpData(_ name: String, at url: URL, index: WADLumpIndex) throws -> Data? {
        guard let (offset, size) = index.offsetSize(of: name) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw WADLumpIndexError.unreadable }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: size)
    }
}
```

- [ ] **Step 4: Run to verify pass** — `xcodebuild ... -only-testing:WADdleTests/WADLumpIndexTests test`. Expected: PASS (4/4).

- [ ] **Step 5: Commit**

```bash
git add App/Sources/WAD/WADLumpIndex.swift App/Tests/WADLumpIndexTests.swift
git commit -m "feat(wad): lump directory index with byte offsets and file-handle reads"
```

---

## Task 2: `DoomGraphics` — palette + picture decode (pure)

Pure, dependency-free decoders. No CoreGraphics — returns raw RGBA so it stays fully unit-testable.

**Files:**
- Create: `App/Sources/WAD/DoomGraphics.swift`
- Test: `App/Tests/DoomGraphicsTests.swift` (new — needs `mise run generate`)

**Interfaces:**
- Produces:
  - `enum DoomGraphics`
  - `static func palette(from playpal: Data) -> [UInt8]?` — 1024 bytes (256 × RGBA, a=255) from the first 768 PLAYPAL bytes; `nil` if shorter.
  - `struct Bitmap: Equatable { let width: Int; let height: Int; let rgba: [UInt8] }` (`rgba.count == width*height*4`, row-major, top-left origin).
  - `static func decodePicture(_ lump: Data, palette: [UInt8]) -> Bitmap?` — decodes the picture (patch) format; `nil` if malformed or `palette` isn't 1024 bytes.

- [ ] **Step 1: Write the failing tests**

Create `App/Tests/DoomGraphicsTests.swift`:

```swift
import XCTest
@testable import WADdle

final class DoomGraphicsTests: XCTestCase {
    func testPaletteReadsFirst256TriplesAsOpaqueRGBA() {
        var playpal = Data([10, 20, 30])                       // index 0
        playpal.append(Data(repeating: 0, count: 768 - 3))     // pad to a full palette
        let pal = DoomGraphics.palette(from: playpal)
        XCTAssertEqual(pal?.count, 256 * 4)
        XCTAssertEqual(pal.map { Array($0[0..<4]) }, [10, 20, 30, 255])
    }

    func testPaletteRejectsShortData() {
        XCTAssertNil(DoomGraphics.palette(from: Data([1, 2, 3])))
    }

    // A synthetic 1x2 picture: column 0 has one post covering both rows with
    // palette indices 3 then 7.
    func testDecodesSinglePostColumn() {
        // header: width=1, height=2, left=0, top=0
        var lump = Data([0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00])
        // columnofs[0] = 12 (u32)
        lump.append(Data([0x0C, 0x00, 0x00, 0x00]))
        // column @12: topdelta=0, length=2, unused, pix[3,7], unused, end=0xFF
        lump.append(Data([0x00, 0x02, 0x00, 0x03, 0x07, 0x00, 0xFF]))

        var pal = [UInt8](repeating: 0, count: 256 * 4)
        pal[3 * 4 + 0] = 30; pal[3 * 4 + 1] = 30; pal[3 * 4 + 2] = 30; pal[3 * 4 + 3] = 255
        pal[7 * 4 + 0] = 70; pal[7 * 4 + 1] = 70; pal[7 * 4 + 2] = 70; pal[7 * 4 + 3] = 255

        let bmp = DoomGraphics.decodePicture(lump, palette: pal)
        XCTAssertEqual(bmp?.width, 1)
        XCTAssertEqual(bmp?.height, 2)
        // (0,0) = idx3, (0,1) = idx7
        XCTAssertEqual(bmp.map { Array($0.rgba[0..<4]) }, [30, 30, 30, 255])
        XCTAssertEqual(bmp.map { Array($0.rgba[4..<8]) }, [70, 70, 70, 255])
    }

    func testRejectsBogusPicture() {
        XCTAssertNil(DoomGraphics.decodePicture(Data([0xFF, 0xFF]), palette: [UInt8](repeating: 0, count: 1024)))
    }
}
```

- [ ] **Step 2: Run to verify fail** — `mise run generate` then `xcodebuild ... -only-testing:WADdleTests/DoomGraphicsTests test`. Expected: FAIL (no `DoomGraphics`).

- [ ] **Step 3: Implement**

Create `App/Sources/WAD/DoomGraphics.swift`:

```swift
import Foundation

/// Pure decoders for the two DOOM binary graphic formats needed for title art.
/// No CoreGraphics — returns raw RGBA so callers build platform images and
/// this stays fully unit-testable.
enum DoomGraphics {
    /// Palette 0 as 256 RGBA entries (1024 bytes, a=255) from a PLAYPAL lump.
    static func palette(from playpal: Data) -> [UInt8]? {
        guard playpal.count >= 768 else { return nil }
        let base = playpal.startIndex
        var out = [UInt8](repeating: 255, count: 256 * 4)
        for i in 0..<256 {
            out[i * 4 + 0] = playpal[base + i * 3 + 0]
            out[i * 4 + 1] = playpal[base + i * 3 + 1]
            out[i * 4 + 2] = playpal[base + i * 3 + 2]
        }
        return out
    }

    struct Bitmap: Equatable { let width: Int; let height: Int; let rgba: [UInt8] }

    /// Decodes the DOOM picture (patch) format into row-major RGBA.
    static func decodePicture(_ lump: Data, palette: [UInt8]) -> Bitmap? {
        guard palette.count == 256 * 4, lump.count >= 8 else { return nil }
        let base = lump.startIndex
        func u16(_ o: Int) -> Int { Int(lump[base + o..<base + o + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian) }
        func u32(_ o: Int) -> Int { Int(lump[base + o..<base + o + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian) }
        func u8(_ o: Int) -> UInt8? { (base + o) < lump.endIndex ? lump[base + o] : nil }

        let width = u16(0), height = u16(2)
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              lump.count >= 8 + width * 4 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)   // transparent by default

        for x in 0..<width {
            var o = u32(8 + x * 4)                                    // column data offset
            while true {
                guard let topdelta = u8(o) else { return nil }
                if topdelta == 0xFF { break }
                guard let length = u8(o + 1) else { return nil }
                let dataStart = o + 3                                 // skip topdelta,length,unused
                guard dataStart + Int(length) <= lump.count else { return nil }
                for r in 0..<Int(length) {
                    let y = Int(topdelta) + r
                    guard y < height else { continue }
                    let idx = Int(lump[base + dataStart + r]) * 4
                    let p = (y * width + x) * 4
                    rgba[p + 0] = palette[idx + 0]
                    rgba[p + 1] = palette[idx + 1]
                    rgba[p + 2] = palette[idx + 2]
                    rgba[p + 3] = 255
                }
                o = dataStart + Int(length) + 1                      // skip trailing unused byte
            }
        }
        return Bitmap(width: width, height: height, rgba: rgba)
    }
}
```

- [ ] **Step 4: Run to verify pass** — `xcodebuild ... -only-testing:WADdleTests/DoomGraphicsTests test`. Expected: PASS (4/4).

- [ ] **Step 5: Commit**

```bash
git add App/Sources/WAD/DoomGraphics.swift App/Tests/DoomGraphicsTests.swift
git commit -m "feat(wad): pure PLAYPAL + picture-format decoders to RGBA"
```

---

## Task 3: `WADArtwork` — orchestrate + cache → CGImage

Finds `TITLEPIC`/`PLAYPAL` across candidate WADs, decodes to a `CGImage` (picture format, or a PNG lump via ImageIO), and disk-caches the result. Runs off the main thread.

**Files:**
- Create: `App/Sources/WAD/WADArtwork.swift`
- Test: `App/Tests/WADArtworkTests.swift` (new — needs `mise run generate`)

**Interfaces:**
- Consumes: `WADLumpIndex.read(from:)`, `WADLumpIndex.lumpData(_:at:index:)`, `DoomGraphics.palette(from:)`, `DoomGraphics.decodePicture(_:palette:)`.
- Produces:
  - `enum WADArtwork`
  - `static func titleImage(candidates: [URL], cacheKey: String) async -> CGImage?` — TITLEPIC from the first candidate that has it; PLAYPAL from the first that has it; PNG-lump aware; disk-cached (PNG) by `cacheKey`; `nil` if none/undecodable. Never runs decode on the caller's actor.

- [ ] **Step 1: Write the failing test**

Create `App/Tests/WADArtworkTests.swift` (builds a synthetic 1×2 IWAD with `TITLEPIC` + `PLAYPAL` so the test is self-contained — no bundle dependency):

```swift
import XCTest
@testable import WADdle

final class WADArtworkTests: XCTestCase {
    // Assemble a WAD from named lumps (offsets computed).
    private func makeWAD(_ lumps: [(String, [UInt8])]) -> Data {
        func i32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: Int32(v).littleEndian) { Array($0) } }
        var body: [UInt8] = []; var dir: [UInt8] = []
        var offset = 12
        for (name, bytes) in lumps {
            dir += i32(offset) + i32(bytes.count)
            var n = Array(name.utf8); n += Array(repeating: 0, count: 8 - n.count); dir += n
            body += bytes; offset += bytes.count
        }
        var out = Array("IWAD".utf8) + i32(lumps.count) + i32(12 + body.count)
        out += body + dir
        return Data(out)
    }

    func testDecodesSyntheticTitlepic() async throws {
        // 1x2 picture, indices 3 then 7; palette makes idx7 = pure red.
        let pic: [UInt8] = [0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
                            0x0C, 0x00, 0x00, 0x00,
                            0x00, 0x02, 0x00, 0x03, 0x07, 0x00, 0xFF]
        var playpal = [UInt8](repeating: 0, count: 768)
        playpal[7 * 3 + 0] = 255  // idx7 red
        let wad = makeWAD([("TITLEPIC", pic), ("PLAYPAL", playpal)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wad")
        try wad.write(to: url); defer { try? FileManager.default.removeItem(at: url) }

        let key = "titleart-test-\(UUID().uuidString)"
        let img = await WADArtwork.titleImage(candidates: [url], cacheKey: key)
        XCTAssertNotNil(img)
        XCTAssertEqual(img?.width, 1)
        XCTAssertEqual(img?.height, 2)
        WADArtwork.clearCache(key: key)   // test hygiene
    }

    func testReturnsNilWhenNoTitlepic() async throws {
        let wad = makeWAD([("PLAYPAL", [UInt8](repeating: 0, count: 768))])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wad")
        try wad.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let img = await WADArtwork.titleImage(candidates: [url], cacheKey: "none-\(UUID().uuidString)")
        XCTAssertNil(img)
    }
}
```

- [ ] **Step 2: Run to verify fail** — `mise run generate` then `xcodebuild ... -only-testing:WADdleTests/WADArtworkTests test`. Expected: FAIL (no `WADArtwork`).

- [ ] **Step 3: Implement**

Create `App/Sources/WAD/WADArtwork.swift`. Requirements the implementer must satisfy (write the code following these; use `ImageIO`/`CoreGraphics`):
- **Cache dir:** `FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TitleArt", isDirectory: true)`; file `"\(cacheKey).png"`. `clearCache(key:)` removes it (used by tests).
- **`titleImage(candidates:cacheKey:) async -> CGImage?`**: run all work inside `await Task.detached(priority: .utility) { ... }.value` so it never executes on the caller's actor.
  1. **Cache hit:** if the cache file exists, decode it with `CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(cacheURL, nil), 0, nil)` and return it.
  2. **Find lumps:** for each URL in `candidates`, `try? WADLumpIndex.read(from:)`; the TITLEPIC source is the first candidate whose index has `TITLEPIC`; the palette source is the first candidate whose index has `PLAYPAL`. If no TITLEPIC source → return `nil`.
  3. **Read TITLEPIC bytes** via `WADLumpIndex.lumpData("TITLEPIC", ...)`.
  4. **PNG branch:** if the bytes start with `89 50 4E 47 0D 0A 1A 0A`, decode with `CGImageSourceCreateWithData(bytes as CFData, nil)` → image; else:
  5. **Picture branch:** read `PLAYPAL` bytes from the palette source; `DoomGraphics.palette(from:)` (fall back to an all-black 256-entry palette if absent so decode still yields a silhouette); `DoomGraphics.decodePicture(...)` → `Bitmap`; build a `CGImage` from `bitmap.rgba` (`CGColorSpaceCreateDeviceRGB()`, `bitsPerComponent: 8`, `bitsPerPixel: 32`, `bytesPerRow: width*4`, `CGImageAlphaInfo.premultipliedLast`, `CGDataProvider(data: Data(bitmap.rgba) as CFData)`).
  6. **Write cache:** encode the `CGImage` to PNG via `CGImageDestinationCreateWithURL(cacheURL, UTType.png.identifier as CFString, 1, nil)` (create the `TitleArt` dir first, `try?`), then return the image. Cache-write failures are non-fatal (`try?`).

- [ ] **Step 4: Run to verify pass** — `xcodebuild ... -only-testing:WADdleTests/WADArtworkTests test`. Expected: PASS (2/2).

- [ ] **Step 5: (Optional) real-WAD spot check.** If `Bundle.main.resourceURL/GameData/freedoom1.wad` is reachable in the test host, add a test decoding it and asserting a non-nil `CGImage` of `width == 320`; guard with `try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))` so it skips where the bundle resource isn't present. Not a gate.

- [ ] **Step 6: Commit**

```bash
git add App/Sources/WAD/WADArtwork.swift App/Tests/WADArtworkTests.swift
git commit -m "feat(wad): TITLEPIC -> CGImage orchestrator with disk cache"
```

---

## Task 4: `TitleArtView` — async load + generated fallback + integrate

Async-loads the art for a `PlayableItem` and shows generated art while loading / on failure; replaces the placeholders in the tile and detail views.

**Files:**
- Create: `App/Sources/UI/TitleArtView.swift`
- Modify: `App/Sources/UI/PlayableTileView.swift`, `App/Sources/UI/PlayableDetailView.swift`, `App/Sources/WAD/WADArtwork.swift` (add the `candidates(for:library:)` resolver)
- Test: `App/Tests/WADArtworkTests.swift` (extend with a resolver unit test)

**Interfaces:**
- Consumes: `WADArtwork.titleImage(candidates:cacheKey:)`, `LibraryService.wad(id:)`, `LibraryService.fileURL(for:)`, `PlayableItem`, `GameFamily`.
- Produces:
  - `@MainActor static func WADArtwork.candidates(for item: PlayableItem, library: LibraryService) -> (urls: [URL], cacheKey: String)?` — base game → `([iwadURL], iwad.sha1)`; preset → primary PWAD first then IWAD (`([pwadURL, iwadURL], pwad.sha1)`), or `([iwadURL], iwad.sha1)` when the preset has no PWAD. `nil` if the IWAD can't be resolved.
  - `struct TitleArtView: View` — `init(item: PlayableItem, library: LibraryService)`.
  - `struct GeneratedArtView: View` — `init(title: String, family: GameFamily)`.

**Implementation spec:**
- **`GeneratedArtView`:** a `RoundedRectangle(cornerRadius: 12)` filled with a color derived from `family` (`.doom1` → `Color.red.opacity(0.35)`, `.doom2` → `Color.orange.opacity(0.35)`, `.unknown` → `Color.gray.opacity(0.3)`), `aspectRatio(1.6, contentMode: .fit)`, overlaid with a monogram `Text` — the first character of up to two whitespace-separated words of `title`, uppercased (e.g. "Freedoom Phase 1" → "FP"), `.font(.title.weight(.bold))`, `.foregroundStyle(.secondary)`. Deterministic (no randomness).
- **`TitleArtView`:** `@State private var image: CGImage?`. Body: if `image != nil`, `Image(decorative: image!, scale: 1).resizable().aspectRatio(1.6, contentMode: .fill).clipShape(RoundedRectangle(cornerRadius: 12))`; else `GeneratedArtView(title: item.title, family: familyForItem)`. In `.task(id: item.id)`: resolve `WADArtwork.candidates(for:library:)` on the main actor, then `image = await WADArtwork.titleImage(candidates:cacheKey:)`. Keep `image == nil` on failure → the generated fallback stays.
- **`familyForItem`:** base game → `wad.gameFamily`; preset → the preset's IWAD family (`library.wad(id: loadout.iwadID)?.gameFamily ?? .unknown`). Add `WADFile.gameFamily: GameFamily { GameFamily(rawValue: gameFamilyRaw) ?? .unknown }` if not already present.
- **`PlayableTileView`:** replace the `RoundedRectangle(...).fill(.quaternary)...overlay(flame)` block with `TitleArtView(item: item, library: library)`. Add `let library: LibraryService` to `PlayableTileView` and pass it from `PlayView.tile(for:canonicalID:)`.
- **`PlayableDetailView`:** replace the header art placeholder with `TitleArtView(item: item, library: library)` (the view already holds `library`).

- [ ] **Step 1: Write the failing resolver test** — add to `App/Tests/WADArtworkTests.swift`:

```swift
    @MainActor
    func testCandidatesForBaseGameUseIWADItself() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, configurations: config)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let service = LibraryService(context: ModelContext(container), store: WADStore(directory: tmp))
        let iwad = try service.registerImported(filename: "doom2.wad", sha1: "iwadsha",
                                                kind: WADKind.iwad.rawValue, family: "doom2")
        let c = WADArtwork.candidates(for: .baseGame(iwad), library: service)
        XCTAssertEqual(c?.urls, [service.fileURL(for: iwad)])
        XCTAssertEqual(c?.cacheKey, "iwadsha")
    }
```

(Add `import SwiftData` to the test file if not present.)

- [ ] **Step 2: Run to verify fail** — `mise run generate` then `xcodebuild ... -only-testing:WADdleTests/WADArtworkTests/testCandidatesForBaseGameUseIWADItself test`. Expected: FAIL (no `candidates`).
- [ ] **Step 3: Implement** the `candidates(for:library:)` resolver in `WADArtwork.swift`, then `GeneratedArtView` + `TitleArtView` in `TitleArtView.swift`, then wire them into `PlayableTileView` (add `library` param + pass from `PlayView`) and `PlayableDetailView`, per the spec above. Add `WADFile.gameFamily` if missing.
- [ ] **Step 4: Run resolver test + build all** — `xcodebuild ... -only-testing:WADdleTests/WADArtworkTests test`, then `xcodebuild ... build-for-testing` (compiles the view changes + `PlayView`'s new `library` argument to the tile).
- [ ] **Step 5: UITest gate** — `xcodebuild ... -only-testing:WADdleUITests/PlayTabTests test`. Expected: PASS (tiles still render + the base-game detail/controls flow is unaffected; the art layer is additive under the same identifiers).
- [ ] **Step 6: Commit**

```bash
git add App/Sources/UI/TitleArtView.swift App/Sources/UI/PlayableTileView.swift App/Sources/UI/PlayableDetailView.swift App/Sources/WAD/WADArtwork.swift App/Tests/WADArtworkTests.swift
git commit -m "feat(play): title-art tiles with generated fallback"
```

---

## Self-Review

**Spec coverage ("Title art" section):**
- Extract `TITLEPIC`, decode DOOM patch format with `PLAYPAL` → Tasks 1-3. ✓
- Palette from the WAD's own or the resolved base IWAD's (`candidates` = `[pwad, iwad]` for presets; palette taken from the first candidate that has `PLAYPAL`) → Tasks 3, 4. ✓
- PNG-signature lump support → Task 3 (PNG branch). ✓
- Cache decoded thumbnail to disk keyed by content hash; decode lazily & off-main-thread; never block launch/import (FileHandle reads only the directory + two lumps, no full-file load) → Tasks 1, 3. ✓
- Generated fallback (family accent color + monogram) when absent/undecodable → Task 4 (`GeneratedArtView`). ✓
- Slots into `PlayableTileView` / `PlayableDetailView` → Task 4. ✓
- Tall-patch running-topdelta and the 14-palette PLAYPAL variants are explicitly out of scope (TITLEPIC is ≤200 tall, palette 0 only) — documented in Global Constraints.

**Placeholder scan:** Tasks 1-2 carry complete implementation + test code; Task 3's implementation is specified as a numbered CoreGraphics/ImageIO recipe (the pure, hardest-to-get-right decoding is fully coded in Tasks 1-2, and Task 3 is platform-API glue best written against the live SDK); Task 4 is SwiftUI wiring specified by interface + behavior against the existing view patterns. No "TBD"/"handle errors" left abstract.

**Type consistency:** `WADLumpIndex.offsetSize(of:)`/`lumpData(_:at:index:)`, `DoomGraphics.palette(from:)`→1024-byte `[UInt8]` consumed by `decodePicture(_:palette:)`→`Bitmap{width,height,rgba}`, and `WADArtwork.titleImage(candidates:cacheKey:)`/`candidates(for:library:)`/`clearCache(key:)` are used with identical signatures across Tasks 1→4. `TitleArtView(item:library:)` / `GeneratedArtView(title:family:)` and the added `PlayableTileView.library` are consistent between their definition (Task 4) and call sites (`PlayView`, `PlayableDetailView`).
