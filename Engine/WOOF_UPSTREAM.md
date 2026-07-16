# Vendored Woof! provenance

- Upstream: https://github.com/fabiangreffrath/woof
- Pin: master commit `798acebd52b6cc1623dde556d3e3a236a25a41d1` (2026-07-12,
  SDL3 ≥ 3.4 tree; reports version 15.2.0)
- Vendored by: `Scripts/vendor-woof.sh`

Previously pinned to tag `woof_15.3.0`, which turned out to be the
SDL2-era tree — incompatible with the SDL3-only iOS dependency set
built in Task 4. Re-pinned to the SDL3 master commit above (plan
corrected in ae876c9).

## iOS patch set

All iOS changes are committed directly to `Engine/woof/` with commit
subjects prefixed `engine:`. Keep the patch set minimal.

Current patches:
- `src/CMakeLists.txt` — on iOS, build `woof` as a STATIC library (replace
  `add_executable(woof ...)` under `if(IOS)`), remove `i_main.c` from its
  sources and add `woof_ios.c`/`woof_ios.h`, define `WOOF_IOS` publicly;
  wrap the `woof-setup` tool target and the `install(TARGETS woof
  woof-setup ...)` rules in `if(NOT IOS)` (no companion setup executable
  on iOS; Task 6 stages the static library into the xcframework directly,
  and `install(TARGETS)` on the missing `woof-setup` is a configure error).
- `src/i_exit.c` — on iOS, `I_SafeExit()` unwinds to the host app via
  `WoofIOS_ExitUnwind()` instead of calling `exit()`, and resets its
  priority counter so a second engine session can run exit handlers again.
- `src/woof_ios.h` / `src/woof_ios.c` — iOS entry point (`WoofIOS_Run`)
  replacing `i_main.c`, plus `WoofIOS_RequestQuit`. `WoofIOS_Run` calls
  `SDL_SetMainReady()` before anything else: the host app's `main()` is
  SwiftUI's synthesized entry point rather than SDL_main, so SDL never
  saw the readiness registration its SDL_main shim normally performs,
  and `SDL_Init` refuses without it. `SDL_MAIN_HANDLED` is defined
  before including `SDL3/SDL_main.h` so the header doesn't also try to
  inject its own `main()`/`UIApplicationMain` trampoline into this
  translation unit.
- `CMakeLists.txt` (top-level) — added `find_package(Threads REQUIRED)`
  before `find_package(OpenAL REQUIRED)`: our Vendor-built OpenAL Soft's
  exported `OpenALTargets.cmake` links `Threads::Threads` in its interface
  without finding it itself, which is a generate-time error for any
  consumer that hasn't already resolved it (Homebrew's OpenAL config
  masks this on macOS). Confirmed still required on this tree. Harmless
  everywhere, so not gated by `if(IOS)`.
- `textscreen/txt_fileselect.c` — `system()`/`fork()`-based external
  file-select dialogs (zenity/osascript) don't exist on iOS and `system()`
  is marked unavailable in the iOS SDK (hard compile error). On
  `TARGET_OS_IPHONE`, use the same "can't select files" stub as `_WIN32`
  and compile out the fork/exec helper.
- `textscreen/txt_window.c` — `TXT_OpenURL()` uses `system()` (hard
  compile error on iOS). Added a `TARGET_OS_IPHONE` stub branch that
  logs instead; opening URLs is up to the host app.
- `src/midiout.c` — the `__APPLE__` CoreMIDI/DLS-synth backend includes
  `CoreAudio/HostTime.h`, which doesn't exist in the iOS SDK. Restricted
  that backend to `__APPLE__ && !TARGET_OS_IPHONE` so iOS falls through
  to upstream's existing DUMMY MIDI backend (music via the OpenAL/opl
  paths is unaffected).

### Task 10: quit/relaunch stale-global fixes

`WoofIOS_Run` may run more than once in the same process (Task 9's
autoquit → `I_SafeExit` → `longjmp` unwind returns to the host app, which
can call it again). Everything below `WoofIOS_Run`/`D_DoomMain` was
written assuming a real process exit ends its lifetime, so several
module-level statics that outlive one `WoofIOS_Run` call and get
re-populated by the next needed WOOF_IOS-only resets or re-registration
guards. Found via the Task 10 XCUITest (cycle 2 first failed with
`Engine exited: -1`; diagnosed from the app's captured stdout/stderr in
the `.xcresult` diagnostics bundle — `xcrun xcresulttool export
diagnostics --path <result>.xcresult --output-path <dir>
--test-plan-run-id 0`, since fprintf output doesn't reach `log stream`).
Two independent bugs, fixed minimally and `#ifdef WOOF_IOS`-guarded
throughout (zero behavior change on other platforms, where `D_DoomMain`
only ever runs once):

- `src/w_wad.c`, `src/w_zip.c`, `src/w_file.c` — first observed failure:
  `mz_zip_reader_extract_to_mem failed` a couple seconds into cycle 2.
  `lumpinfo`/`wadfiles`/`numlumps` (w_wad.c) and each WAD-source module's
  own directory (`archives` in w_zip.c, `descriptors` in w_file.c) are
  realloc-backed arrays (m_array.h) or module-private tables that
  `W_InitMultipleFiles()` appends to on every session but nothing ever
  cleared. A second session's fresh entries landed *after* the first
  session's stale ones instead of replacing them: `wadfiles[0]` (read
  all over `d_main.c`/`g_game.c` as "the IWAD name") stayed pinned to the
  first session's entry, and a lump lookup landing on a stale
  `lumpinfo` entry dereferenced a `w_zip.c` archive already torn down by
  `mz_zip_reader_end()` — hence the extract failure. Fixed by having each
  module's existing `Close()` (already registered via `I_AtExitPrio(...,
  true /* run_on_error */, ..., exit_priority_last)`, so it always runs
  before the next session, even after an `I_Error`) fully free and reset
  its own arrays, and having `W_Close()` do the same for `lumpinfo`/
  `wadfiles`/`numlumps`.
- `src/m_config.c`, `src/mn_setup.c` — second failure, after the above:
  `I_Error("Could not find config variable ...")` reading garbage bytes
  as a key name. `M_InitConfig()` rebuilds the `defaults` array (also
  m_array.h) from scratch every session by design of the fix above's
  first draft, but `MN_InitDefaults()` (mn_setup.c) performs a
  *destructive, one-time* conversion: it overwrites each menu item's
  `var.name` (a string) with `var.def` (a `default_t*` into `defaults`)
  through a union. Rebuilding `defaults` a second time orphaned those
  pointers, and re-running `MN_InitDefaults()` (which also runs every
  `D_DoomMain()`) tried to read the already-overwritten union back out as
  a string. Since the bound variable addresses and the menu/config
  metadata describing them never change across sessions in the same
  process, the correct fix is not to reset and rebuild — it's to guard
  both `M_InitConfig()` and `MN_InitDefaults()` to run their
  (idempotent-only-once) registration exactly once per process; the
  per-session `M_LoadDefaults()` call (unguarded, naturally idempotent)
  still re-applies the saved config every session.
- `src/woof_ios.c` — third failure (fix round 1), exposed only after the
  above two were fixed and the gate was hardened to require each session
  to survive its full autoquit window: session 2 exited cleanly (code 0)
  ~2 s in, *before* entering the title/demo loop, so the relaunch cycle
  "passed" while the second session was actually dead. Diagnosed with a
  temporary `SA_SIGINFO` probe: the XCUITest harness (`xcodebuild`;
  `si_pid` = its pid, `si_code` = `SI_USER`) delivers a stray SIGTERM to
  the app-under-test moments after the second session's SDL window
  appears. SDL3's default signal handling (`SDL_quit.c`) converts SIGTERM
  into `SDL_EVENT_QUIT` — a desktop graceful-quit convention with no
  counterpart on iOS (apps get lifecycle callbacks and SIGKILL, never a
  polite SIGTERM) — and the engine obligingly quit. Fix: `WoofIOS_Run`
  sets `SIG_IGN` for SIGTERM for the duration of each session (installed
  *before* `SDL_Init`, which also stops SDL claiming the signal:
  `SDL_EventSignal_Init` only overrides a `SIG_DFL` disposition) and
  restores the previous disposition on unwind, so process teardown
  outside a session behaves normally. In-app quits are unaffected (they
  push `SDL_EVENT_QUIT` directly). Residual risk: a harness SIGTERM
  landing in the sub-second gap *between* sessions would kill the process
  (default action); not observed — it has only ever arrived while a
  session was running. This file is iOS-only, so no `WOOF_IOS` guard is
  needed.

Related (not upstream files): `Scripts/build-engine.sh` passes
`-DCMAKE_FIND_ROOT_PATH="$OUT/$platform"` in addition to
`-DCMAKE_PREFIX_PATH`. When `CMAKE_SYSTEM_NAME=iOS`, CMake restricts
`find_package` to `CMAKE_FIND_ROOT_PATH` (seeded with just the SDK
sysroot), so `CMAKE_PREFIX_PATH` alone is silently ignored — confirmed
still the case on this tree (configure fails to find SDL3 without it).
Do not switch to `CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH` instead: that
lets `find_package` silently fall through to host Homebrew packages
(observed resolving a macOS SDL for an iOS build under the previous pin).

Also in `Scripts/build-engine.sh`: exports `PKG_CONFIG_LIBDIR=""` and
`PKG_CONFIG_PATH=""` before configuring. `CMAKE_FIND_ROOT_PATH` has no
effect on `find_package(... QUIET)` calls that resolve via pkg-config
(`FindPkgConfig.cmake` shells out to the system `pkg-config`, which has
its own search path independent of CMake's). Without this,
`third-party/CMakeLists.txt`'s `find_package(libebur128 QUIET)` resolved
to a Homebrew-installed macOS dylib on the build machine instead of
falling back to the vendored `third-party/libebur128` source, producing
a `woof` static-library target with a link *requirement* that never
turns into an actual archive our xcframework assembly can merge — the
app's final link then fails with undefined `ebur128_*` symbols.

## Updating to a new upstream pin

1. `git log --oneline -- Engine/woof` and note the `engine:` patch commits.
2. Update `WOOF_COMMIT` in `Scripts/vendor-woof.sh`, run it (this wipes the
   tree).
3. Commit the new pristine tree as `engine: vendor Woof! <commit>`.
4. Re-apply each patch commit with `git cherry-pick` (or by hand), resolving
   conflicts against the new tree.
5. Rebuild and re-run the simulator smoke test (Task 10) before merging.
