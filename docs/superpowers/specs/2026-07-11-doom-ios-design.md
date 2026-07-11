# Doom for iOS — Design Spec

**Date:** 2026-07-11
**Status:** Approved pending user review
**Working name:** "BoomBox" (placeholder; user picks the real App Store name before submission)

## 1. Summary

A free, open-source iOS app (iPhone + iPad) that plays Doom-engine games at
Boom/MBF21 compatibility level using a vendored fork of the **Woof!** source
port. It bundles **Freedoom Phase 1 + 2** so it is fully playable on first
launch, and lets users import their own IWADs and PWADs via the Files app,
stack them into named **loadouts** (IWAD + ordered PWADs/DEH patches), and
keep per-loadout save games. It replaces the old "one app per WAD" model
(id/Tom Kidd DOOM-iOS lineage) with a single app and a WAD library.

**Not** in scope: GZDoom-tier content (ZScript/full UDMF, e.g. MyHouse.wad).
That niche is served by GenZD on the App Store. Our tier covers vanilla,
Boom, MBF, and MBF21 + UMAPINFO + DEHEXTRA + ID24 — i.e. the large majority
of celebrated community megawads (Sunlust, Eviternity I/II, BTSX, most
Cacoward winners) with demo-accurate physics.

## 2. Decisions made (with rationale)

| Decision | Choice | Rationale |
|---|---|---|
| Compatibility tier | Boom/MBF21 (+UMAPINFO, DEHEXTRA, ID24) | Covers most modern megawads; lightweight, portable engines; open niche on iOS (GenZD covers GZDoom tier; nobody ships MBF21) |
| Engine | **Woof!** (fork, git submodule) | Very active upstream; clean C; **SDL3** (first-class iOS); pure software renderer (no OpenGL/translation layers); GPL-2.0 |
| Pricing | Free, no monetization | Cleanest GPL-on-App-Store posture and Freedoom bundling |
| Bundled content | Freedoom Phase 1 + 2 | BSD-licensed, explicitly redistributable; app fully functional for App Review without user files |
| Devices/input | iPhone + iPad; touch, game controllers, keyboard & mouse | All requested at launch; SDL3 wraps GameController/GCMouse/GCKeyboard |
| WAD management | Library + loadouts (IWAD + ordered PWADs/DEH), per-loadout saves | How modern megawads are actually played |
| iOS target | iOS 16+ | SwiftUI/SwiftData baseline; software renderer runs on anything |

### Alternatives considered
- **dsda-doom:** community standard, adds Heretic/Hexen + partial UDMF, but
  SDL2 and a more entangled GL renderer; rejected for v1 (harder port for
  features out of scope).
- **GZDoom/UZDoom:** everything-tier but heavy C++, GPLv3, MoltenVK stack,
  Oct 2025 governance fork, and GenZD already occupies the niche.
- **Multi-engine (Delta Touch model):** multiplies all porting work; rejected.

## 3. Architecture

Two halves in one app:

1. **Native frontend (Swift/SwiftUI)** — launcher: WAD library, loadout
   builder, settings, touch-control overlay. All product differentiation
   lives here.
2. **Engine core (C)** — vendored **Woof!** fork built as a static library,
   plus **SDL3** (≥ 3.4, Woof requirement) and **OpenAL Soft** built as iOS
   xcframeworks. Woof's software renderer blits through SDL3's Metal-backed
   presentation. No OpenGL anywhere.

### Components
- **Engine wrapper** (`EngineSession`): configures args
  (`-iwad/-file/-deh/-savedir/-complevel`), presents the SDL view, runs the
  engine, and returns control + exit status to SwiftUI.
- **iOS patch set on Woof** (kept minimal, rebased on upstream releases):
  - Quit path: `exit()`/`I_Error` unwound back to the frontend instead of
    terminating the process (iOS apps must not self-terminate).
  - Full engine teardown/reinit between sessions (play → quit → new loadout
    → play, one process).
  - File paths: config/saves under app container; WAD search paths pointed
    at `Documents/WADs/` and the bundle.
  - SDL lifecycle: pause on background, handle memory warnings.
- **WAD Library** (Swift): import, validation, classification, storage,
  dedupe.
- **Loadout manager** (Swift): loadout CRUD, engine-arg mapping, save-dir
  keying.
- **Touch overlay** (Swift/UIKit on top of the SDL view): virtual movement
  stick, drag-to-turn on right half, fire/use/weapon/automap buttons;
  injects synthetic input events into the engine. Layout tuned on device;
  full user customization is v2.
- **Input passthrough:** controllers (Xbox/PS/Switch/MFi), Bluetooth
  keyboard, and mouse (relative input for real mouselook on iPad) come via
  SDL3's iOS backend; `UIApplicationSupportsIndirectInputEvents` enabled.
- **Audio:** OpenAL Soft for SFX; music via Woof's built-in OPL3 emulator.
  FluidSynth/soundfonts deferred to v2.

## 4. WAD library & data model

**Import paths:** Files app visibility (`UIFileSharingEnabled`,
`LSSupportsOpeningDocumentsInPlace`), in-app `UIDocumentPickerViewController`,
and registered document types for `.wad`, `.deh`, `.bex`, `.zip` ("Open in…").
Zips are auto-extracted; contained WADs/DEH files are imported, the rest
discarded.

**Validation & classification on import:**
- Check 12-byte header magic (`IWAD`/`PWAD`); reject junk with a specific
  message; SHA-1 hash for dedupe.
- IWADs identified by canonical lumps (Doom, Doom II, Plutonia, TNT,
  Freedoom phases…).
- PWADs get a best-effort base-game hint (`ExMy` vs `MAPxx` map lumps,
  texture lumps) — a suggestion, never a hard block.

**SwiftData model:**
- `WADFile`: filename, display name, SHA-1, kind (IWAD/PWAD/DEH), detected
  game, import date. Files stored in `Documents/WADs/`.
- `Loadout`: name, IWAD ref, ordered PWAD/DEH refs, optional complevel
  override (default: Woof auto-detect), last-played. Maps 1:1 to engine args.
- Saves: per-loadout directory via `-savedir`, keyed by loadout ID.
  Sunlust and Eviternity saves never collide.

**Referential rules:** deleting a loadout offers to delete its saves;
deleting a WAD file warns when loadouts reference it. Bundled Freedoom
IWADs appear in the library, read-only and undeletable; "Freedoom Phase 1"
and "Phase 2" loadouts are pre-created on first run.

**Launcher UI:** home = loadout grid, prominent Play on most recent;
library tab = imported files; loadout editor = pick IWAD → add/reorder
PWADs/DEH → play. Tapping a lone PWAD offers "New loadout with
[detected IWAD]".

## 5. Error handling

- **Import:** bad magic/truncated → specific rejection message; duplicate
  hash → "already in library."
- **Engine:** `I_Error` (missing lumps, bad DEH, malformed maps) is caught
  and routed back to the launcher; the alert shows the engine's actual
  error text plus a wrong-IWAD-pairing hint when applicable. A bad WAD must
  never crash the app.
- **Lifecycle:** background = engine pause; memory warnings handled; if a
  session dies mid-game the loadout is flagged so a corrupt autosave can't
  cause a relaunch loop.

## 6. Testing

- **Unit (XCTest):** WAD parsing/classification, hashing/dedupe,
  loadout→args mapping, save-dir keying. Fixtures: tiny hand-built WADs +
  Freedoom.
- **Simulator:** everything runs in the iOS Simulator (software renderer);
  `xcodebuild` + `simctl` drive build/launch/UI tests from the CLI.
- **Engine smoke test:** boot each bundled IWAD into the demo loop; assert
  frames advance and quit-to-launcher returns cleanly, twice in a row
  (teardown/reinit proof).
- **Real WADs:** user-supplied Boom-tier and MBF21-tier megawads verified
  on simulator and device.

## 7. Compliance & distribution

- Free app; full app + engine-fork source published on GitHub under
  **GPL-2.0** (engine license governs). This mirrors the tolerated practice
  of RetroArch and GenZD (both live on the App Store since 2024).
- Freedoom's BSD license text included in-app; no commercial or shareware
  WADs bundled or linked; user-supplied content only (Files-app import —
  the pattern App Review has repeatedly approved post-2024 guideline 4.7).
- No analytics, no network access in v1 → minimal privacy label.

## 8. Risks

1. **Quit-to-launcher/reinit patch** — Woof uses globals; full teardown may
   take iteration. Fallback: "restart session" that recreates the SDL window
   while keeping the process.
2. **SDL3 ≥ 3.4 + OpenAL Soft xcframework builds** — routine but real setup
   work.
3. **GPL on the App Store** — de facto tolerated, not settled law; mitigated
   by free pricing + published source.
4. **Touch-control feel** — expect on-device tuning iterations.

## 9. Out of scope for v1

Multiplayer, FluidSynth/soundfonts, Heretic/Hexen, GZDoom-tier content, WAD
metadata scraping, touch-layout customization UI, tvOS.
