# Vendored Woof! provenance

- Upstream: https://github.com/fabiangreffrath/woof
- Tag: `woof_15.3.0`
- Vendored by: `Scripts/vendor-woof.sh`

## iOS patch set

All iOS changes are committed directly to `Engine/woof/` with commit
subjects prefixed `engine:`. Keep the patch set minimal.

Current patches:
- `src/CMakeLists.txt` — on iOS (`elseif(IOS)` next to the existing `WIN32`
  branch of the `woof` target), build `woof` as a STATIC library, remove
  `i_main.c` from its sources and add `woof_ios.c`/`woof_ios.h`, and define
  `WOOF_IOS` publicly. Also wraps the `woof-setup` tool target and the
  `install(TARGETS woof woof-setup ...)` rules in `if(NOT IOS)`, since
  iOS has no companion setup executable and Task 6 stages the static
  library into the xcframework directly rather than via `install()`.
- `src/i_system.c` — **not `src/i_exit.c`** as originally planned: this
  vendored tree keeps `I_SafeExit()` in `i_system.c` (there is no
  `i_exit.c` file in Woof 15.3.0). On iOS, `I_SafeExit()`'s final
  `exit(rc)` is replaced with a call to `WoofIOS_ExitUnwind()`, and
  `exit_priority` is reset first so a second engine session in the same
  process can run its own exit handlers again.
- `src/woof_ios.h` / `src/woof_ios.c` — iOS entry point (`WoofIOS_Run`)
  replacing `i_main.c`, plus `WoofIOS_RequestQuit`.
- `CMakeLists.txt` (top-level) — added `find_package(Threads REQUIRED)`
  before `find_package(OpenAL REQUIRED)`. Not iOS-specific: our vendored
  OpenAL Soft's exported `OpenALTargets.cmake` links `Threads::Threads`
  in its interface without finding it itself, so any consumer that hasn't
  already resolved `Threads::Threads` (as e.g. Homebrew's OpenAL happens
  to have on macOS, masking the gap during the Task 3 smoke build) fails
  at generate time with "the target was not found". Harmless everywhere.
- `Scripts/build-engine.sh` — passes `-DCMAKE_FIND_ROOT_PATH="$OUT/$platform"`
  in addition to `-DCMAKE_PREFIX_PATH`. When `CMAKE_SYSTEM_NAME=iOS`,
  CMake restricts `find_package`/`find_library` to `CMAKE_FIND_ROOT_PATH`
  (which Apple's platform module seeds with just the SDK sysroot), so
  `CMAKE_PREFIX_PATH` alone is silently ignored for Vendor/out and even
  the already-built OpenAL is never found. Appending to
  `CMAKE_FIND_ROOT_PATH` (mode stays the default `ONLY`) is the safe fix;
  setting `CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH` instead was tried and
  rejected — it also lets `find_package` fall through to the host's
  Homebrew packages (confirmed: it silently resolved `SDL2_DIR` to
  `/opt/homebrew/lib/cmake/SDL2`, a macOS dylib, for an iOS-simulator
  build), which would be a much worse, silent failure mode.

### Known blocker: engine is written against the SDL2 API, only SDL3 is vendored for iOS

`Scripts/build-engine.sh` does not yet produce `libwoof.a` for either iOS
platform. Configure fails at `find_package(SDL2 2.0.18 REQUIRED)`
(`Engine/woof/CMakeLists.txt:97`, after the `Threads` fix above) because
Task 4 only built **SDL3** 3.4.12 into `Vendor/out` — no SDL2, and no
`sdl2-compat`-style shim is present. This is not one of the small,
guardable "iOS-specific compile issues" (POSIX APIs, `TARGET_OS_*`
branches, configure-time install rules) anticipated for Task 5 iteration.
It's a real API-shape mismatch, confirmed by direct inspection of the
vendored source, e.g.:
- `i_video.c`: `SDL_CreateWindow(title, window_x, window_y, w, h, flags)`
  (SDL2's 6-argument signature; SDL3 dropped the `x, y` params),
  `SDL_Init(SDL_INIT_VIDEO) < 0` (SDL3's `SDL_Init` returns `bool`, so this
  comparison is meaningless even where it happens to still compile),
  `SDL_WINDOW_FULLSCREEN_DESKTOP` (removed in SDL3).
- `net_sdl.c` calls `SDLNet_*` from `<SDL_net.h>` (SDL2_net); there is no
  SDL3_net build in `Vendor/out` either.
- At least `i_input.c`, `i_rumble.c`, and `i_timer.c` also use SDL2-only
  constructs.
- Two more Vendor libraries are `REQUIRED` unconditionally at the top of
  `CMakeLists.txt` with no `if(IOS)`/optional gate and were never built
  for iOS in Task 4 either: `libebur128` and `SndFile` (≥1.0.29).

None of this is fixable by a small guarded patch to Woof source without
either (a) provisioning a real SDL2-API-compatible library for iOS in
`Vendor/out` — e.g. the `sdl2-compat` shim (confirmed to work with this
exact vendored source already: the working Task 3 macOS smoke build
resolves `find_package(SDL2 ...)` to Homebrew's `sdl2-compat` 2.32.70,
*not* real SDL2 — Homebrew's `sdl2` formula **is** sdl2-compat, and it
works with this source unmodified) plus `SDL2_net`, `libebur128`, and
`SndFile` for iOS, or (b) a dedicated, carefully-tested SDL2→SDL3 source
port of the engine's platform layer (video/input/timer/audio/gamepad/net)
across a dozen-plus files. Both are out of scope for "keep the iOS patch
set minimal" / "pure C changes" and belong in a follow-up task with
explicit sign-off on which path to take — see `task-5-report.md` for the
full analysis and recommendation.

The static-lib CMake target logic itself (`elseif(IOS)` block, `i_main.c`
exclusion, `woof_ios.c` inclusion, `WOOF_IOS` define, `woof-setup`/
`install()` skip) was verified independently of this blocker: configuring
the real project against the real Vendor-built OpenAL plus throwaway stub
`find_package` modules for SDL2/SDL2_net/libebur128/SndFile produces a
correct `add_library(woof STATIC ...)` ninja target — `i_main.c.o` absent,
`woof_ios.c.o` present, `-DWOOF_IOS` on the compile line, arm64 iOS
simulator sysroot flags — with no `woof-setup` target and no install-rule
errors. That test was not committed (it used fake, non-functional stub
modules purely to isolate CMake-logic correctness from the real
dependency gap).

## Updating to a new upstream release

1. `git log --oneline -- Engine/woof` and note the `engine:` patch commits.
2. Update `WOOF_TAG` in `Scripts/vendor-woof.sh`, run it (this wipes the tree).
3. Commit the new pristine tree as `engine: vendor Woof! <tag>`.
4. Re-apply each patch commit with `git cherry-pick` (or by hand), resolving
   conflicts against the new tree.
5. Rebuild and re-run the simulator smoke test (Task 10) before merging.
