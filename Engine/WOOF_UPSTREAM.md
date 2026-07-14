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
  replacing `i_main.c`, plus `WoofIOS_RequestQuit`.
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

Related (not upstream files): `Scripts/build-engine.sh` passes
`-DCMAKE_FIND_ROOT_PATH="$OUT/$platform"` in addition to
`-DCMAKE_PREFIX_PATH`. When `CMAKE_SYSTEM_NAME=iOS`, CMake restricts
`find_package` to `CMAKE_FIND_ROOT_PATH` (seeded with just the SDK
sysroot), so `CMAKE_PREFIX_PATH` alone is silently ignored — confirmed
still the case on this tree (configure fails to find SDL3 without it).
Do not switch to `CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH` instead: that
lets `find_package` silently fall through to host Homebrew packages
(observed resolving a macOS SDL for an iOS build under the previous pin).

## Updating to a new upstream pin

1. `git log --oneline -- Engine/woof` and note the `engine:` patch commits.
2. Update `WOOF_COMMIT` in `Scripts/vendor-woof.sh`, run it (this wipes the
   tree).
3. Commit the new pristine tree as `engine: vendor Woof! <commit>`.
4. Re-apply each patch commit with `git cherry-pick` (or by hand), resolving
   conflicts against the new tree.
5. Rebuild and re-run the simulator smoke test (Task 10) before merging.
