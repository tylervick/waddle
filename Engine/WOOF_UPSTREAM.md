# Vendored Woof! provenance

- Upstream: https://github.com/fabiangreffrath/woof
- Pin: master commit `1462fadc90a4589c9cfc246d9e014ed5f02a2e54` (2026-10-01,
  SDL3 ≥ 3.4 tree; reports version 16.0.0). The pristine tree is the commit
  `engine: vendor Woof! master 1462fadc (16.0.0 tree)`; the iOS patch set is
  exactly what `git diff <that commit> -- Engine/woof` shows (59 files).
- Previous pin: master `798acebd` (2026-07-12, 15.2.0; pristine commit
  `9bea4bb`), carried from Plan 1 until the 2026-10-03 re-vendor (issue #79).
- Vendored by: `Scripts/vendor-woof.sh` -- only as step 3 of the procedure at
  the end of this file; run on its own it wipes the patch set.

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
  Also (Plan 4): `I_AtSignal()` skips a `func` already in `atsignal_funcs`
  (identity check) under `WOOF_IOS` — every session's `D_DoomMain`
  re-registers the same handlers, and unlike the exit lists (drained by
  `I_SafeExit` each session) nothing ever drains the signal list short of
  an actual fatal signal, so it grew by one entry set per session.
- `src/woof_ios.h` / `src/woof_ios.c` — iOS entry point (`WoofIOS_Run`)
  replacing `i_main.c`, plus `WoofIOS_RequestQuit`. `WoofIOS_Run` calls
  `SDL_SetMainReady()` before anything else: the host app's `main()` is
  SwiftUI's synthesized entry point rather than SDL_main, so SDL never
  saw the readiness registration its SDL_main shim normally performs,
  and `SDL_Init` refuses without it. `SDL_MAIN_HANDLED` is defined
  before including `SDL3/SDL_main.h` so the header doesn't also try to
  inject its own `main()`/`UIApplicationMain` trampoline into this
  translation unit. `WoofIOS_ExitUnwind` refuses to `longjmp` from any
  thread other than the one that entered `WoofIOS_Run` (aborts instead):
  `I_Error` is occasionally reachable from helper threads, and unwinding
  a foreign stack is undefined behavior. Each session also clears the
  previous session's accumulated error text via `I_ResetErrorMessages()`.
  Plan 4 Task 7b added `SDL_SetHint(SDL_HINT_ORIENTATIONS, ...)` (all four
  orientations) before `D_DoomMain`: without the hint, SDL's
  `UIKit_GetSupportedOrientations` falls back to the window's aspect ratio
  for a non-resizable window, and Woof's wider-than-tall window locked the
  interface to landscape for the whole session — device rotation was
  ignored. SDL intersects the hint with the app's Info.plist orientation
  mask, so the plist stays authoritative.
  Plan 3 Task 1 added a touch-control shim: `WoofIOS_AttachTouchGamepad`/
  `WoofIOS_DetachTouchGamepad`/`WoofIOS_SetTouchAxis`/`WoofIOS_SetTouchButton`
  drive a virtual `SDL_JOYSTICK_TYPE_GAMEPAD` joystick that the native
  overlay owns, and `WoofIOS_GetUIWindowPointer` exposes the SDL window's
  `UIWindow*` for the overlay to attach into. No fallback attach hook was
  needed: verified that Woof! auto-opens a gamepad attached mid-session
  through its existing `SDL_EVENT_GAMEPAD_ADDED` handling —
  `src/i_video.c:517-519` (`ProcessEvent`) calls `I_OpenGamepad(ev->gdevice.which)`
  unconditionally on that event (not gated on `joy_device`/`I_GamepadEnabled`),
  and `I_OpenGamepad` (`src/i_input.c:566-604`) opens it via
  `SDL_OpenGamepad` when no gamepad is already active. SDL fires
  `SDL_EVENT_GAMEPAD_ADDED` for the virtual joystick because
  `SDL_IsGamepad()` resolves true for it: the virtual-joystick driver
  tags the synthesized GUID's type byte with `SDL_JOYSTICK_TYPE_GAMEPAD`
  (`Vendor/src/SDL/src/joystick/virtual/SDL_virtualjoystick.c:234`) and,
  since the shim leaves `button_mask`/`axis_mask` zeroed, auto-fills both
  from `naxes`/`nbuttons` (same file, ~198-231) with a 1:1 index mapping
  covering every `SDL_GAMEPAD_BUTTON_*`/`SDL_GAMEPAD_AXIS_*`. Turn does
  *not* go through an SDL event: `WoofIOS_InjectRelativeTurn` adds to a
  shim-owned accumulator (`touch_turn_accum`) drained once per tic by a
  small hook in `src/i_input.c` (see that bullet below) — see fix round 1
  for why the originally-planned `SDL_PushEvent(SDL_EVENT_MOUSE_MOTION)`
  design was a no-op.

  Fix round (device testing, post-Plan-3): FIRE autofired forever in-game
  after a single press. `WoofIOS_SetTouchAxis` drove `input_fire`'s
  `GAMEPAD_RIGHT_TRIGGER` as a scaled float, but the virtual joystick's
  auto-generated mapping exposes both trigger inputs as FULL-RANGE axes —
  plain `a4`/`a5`, no `+`/`-` half-axis prefix, because
  `VIRTUAL_JoystickGetGamepadMapping` sets each trigger's mapping `.kind`
  to `EMappingKind_Axis` without a `half_axis_positive`/`negative` flag
  (`Vendor/src/SDL/src/joystick/virtual/SDL_virtualjoystick.c:953-961`) and
  the mapping-string serializer only emits a prefix when one of those
  flags is set
  (`Vendor/src/SDL/src/joystick/SDL_gamepad.c:2285-2290`). SDL linearly
  remaps that full raw range onto the trigger's `0..SDL_JOYSTICK_AXIS_MAX`
  gamepad-axis output, so a released trigger written as raw `0` (a scaled
  float `0.0`) read back as gamepad-axis ~50% — permanently above
  `trigger_threshold` (`src/i_gamepad.c`). Added `WoofIOS_SetTouchTrigger`,
  which instead writes the raw axis to `SDL_JOYSTICK_AXIS_MAX`/`_MIN`
  digitally (press/release only, no partial pull), and initializes both
  trigger axes to `SDL_JOYSTICK_AXIS_MIN` right after attach (a virtual
  joystick's axes default to `0`, which under this mapping is the same
  ~50%-pulled latent bug at session start, before any touch). Also added
  `WoofIOS_DebugTriggerValue` (test/debug telemetry only): opens a
  gamepad-layer view of `touch_joystick` — eagerly, right after attach, not
  lazily on first call, because empirically a just-opened `SDL_Gamepad`'s
  very first `SDL_GetGamepadAxis` read after an axis change can observe a
  stale value — and returns `SDL_GetGamepadAxis(..., SDL_GAMEPAD_AXIS_RIGHT_TRIGGER)`
  normalized to `0..1`, i.e. the value Woof's `TriggerToButton`
  (`src/i_input.c`) actually reads, not just the raw value the overlay
  wrote. This is what the app's debug HUD and the regression test
  (`TouchControlsTests.testFireReleaseClearsTriggerResidue`) both sample.

  Second fix round (device testing): MAP did nothing (wired to
  `SDL_GAMEPAD_BUTTON_BACK`, which has no entry anywhere in `m_input.c`'s
  `default_inputs` table — guessed, not verified, same mistake class as
  the FIRE/USE mixup above). Rewired to `GAMEPAD_NORTH`
  (`input_map`, `m_input.c:689-690`), which is correct for gameplay but
  collides with a *menu-context* binding on the same physical button:
  `m_input.c:624-628` also binds NORTH to `input_menu_clear`, and
  `m_input.c:564,576` binds SOUTH (USE) to `gamepad_confirm`. In the
  Load/Save menu, a `MENU_CLEAR` action on a populated slot arms a delete
  confirmation (`delete_verify`, `mn_menu.c:3368-3378`, gated on
  `AnyLoadSaveMenu()` + `AllowDeleteSaveGame()`), and a following
  `MENU_ENTER` confirms `M_DeleteGame` (`mn_menu.c:2806-2814`) — two
  overlay taps (MAP then USE) could silently delete a save with no visible
  prompt on the touch overlay. Rather than move MAP off its correct
  gameplay default, added `WoofIOS_IsMenuActive`, a thin wrapper reading
  the engine's own `menuactive` global (`doomstat.h:251`, defined
  `mn_menu.c:104`) — true only while an actual menu screen is overlaying
  the game (title/demo state does not set it). The touch overlay
  (`TouchOverlayView`) polls this on a lightweight always-on timer
  (independent of the debug HUD, which is opt-in) and hides the automap
  button whenever a menu is up, restoring it the instant the menu closes.
- `src/i_input.c` — `I_ReadMouse()` gets a `WOOF_IOS`-only hook, added in
  Plan 3 Task 1 fix round 1: right after the existing
  `SDL_GetRelativeMouseState(&ev.data1.f, &ev.data2.f)` call, add
  `ev.data1.f += WoofIOS_ConsumeTouchTurn();`. Rationale: the touch
  overlay's relative-turn drag has no real mouse to move, so it can't
  reach `I_ReadMouse` through SDL's normal path —
  `SDL_GetRelativeMouseState()` reads an internal accumulator that only
  `SDL_SendMouseMotion()` (not public API) updates, and
  `src/i_video.c`'s `ProcessEvent` has no `SDL_EVENT_MOUSE_MOTION` case
  to relay a pushed event into it either. `WoofIOS_ConsumeTouchTurn()`
  (declared in `woof_ios.h`, engine-internal) drains and zeroes the
  shim's own accumulator every call, so the touch contribution folds
  straight into the same float `I_ReadMouse` already posts as `ev_mouse`
  — no separate event type, no truncation (both are `float`).
- `src/i_system.c` — added a `WOOF_IOS`-only `I_ResetErrorMessages()`:
  `I_ErrorInternal()` deliberately appends to its static `errmsg` buffer
  so nested errors within one exit sequence share a dialog, but across
  engine sessions in the same process that text is stale and would be
  prepended to the next session's first error dialog. Same block also
  adds a read-only `I_GetErrorMessage()` accessor (returns `errmsg`;
  empty string after a clean exit) so the host app can surface the
  engine's actual error text in its own alert after a session unwinds —
  SDL's `I_ErrorMsg` message box never fires in the iOS embedding. Both
  are declared via local `extern` in `woof_ios.c`, not in `i_system.h`.
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
- `src/woof_ios.c` — fourth instance of the same hazard, caught in review
  during Plan 3 Task 1 (fix round 1) rather than by the XCUITest: the
  touch-control shim's own statics (`touch_joystick`, `touch_joystick_id`,
  `touch_turn_accum`) outlive a session the same way everything above
  does. `SDL_Quit`'s exit handlers free every open joystick — including
  the virtual gamepad `touch_joystick` points at — before
  `WoofIOS_ExitUnwind` ever runs, so by the time the next
  `WoofIOS_Run` starts, `touch_joystick` is dangling, not just detached.
  `WoofIOS_DetachTouchGamepad()` now checks `SDL_WasInit(SDL_INIT_JOYSTICK)`
  first and only nulls its statics (skipping `SDL_CloseJoystick`/
  `SDL_DetachVirtualJoystick`) when the subsystem is already torn down,
  and `WoofIOS_Run`'s unwind branch (`code != 0`, right after restoring
  the SIGTERM disposition) explicitly resets `touch_joystick`,
  `touch_joystick_id`, and `touch_turn_accum` so the next session's
  `WoofIOS_AttachTouchGamepad` attaches fresh. This file is iOS-only, so
  no `WOOF_IOS` guard is needed here either.
- `src/d_demoloop.c` — fifth instance, and the one behind a confirmed
  TestFlight crash (build 2, `EXC_CRASH (SIGABRT)` /
  `POINTER_BEING_FREED_WAS_NOT_ALLOCATED` in `D_SetupDemoLoop` → `D_DoomMain`
  → `WoofIOS_Run`, on a user's 2nd+ play in one launch). The file-scope
  `demoloop` (`m_array`, `m_array.h`) / `demoloop_count` globals outlive a
  session. On the common path `D_GetDefaultDemoLoop` assigns `demoloop` to a
  *static* C array (`demoloop_registered/retail/commercial`); that array is
  never reset. Session 1 never runs `D_CheckPrimaryLumps` — `demoloop` is
  still NULL when it's tested (no `DEMOLOOP` lump to parse), so the default is
  installed *after* the lump check. Session 2 re-enters with `demoloop` still
  pointing at that static array, so `if (demoloop)` is now true and
  `D_CheckPrimaryLumps` runs on it; if the current IWAD is missing one of the
  default demoloop's primary lumps it calls `array_free(demoloop)` — an
  `m_array` free of memory located *before* the static array (the `m_array`
  header sits ahead of the data pointer) → the abort. (An `array_push` onto
  the stale static would corrupt the same way when a `DEMOLOOP` lump is
  present.) Reproduced by playing a retail/commercial IWAD that *has* DEMO4
  (e.g. bundled Freedoom, leaving `demoloop_count == 7`) then Doom II (no
  DEMO4): `D_CheckPrimaryLumps` walks all 7 entries, finds DEMO4 missing at
  index 6, and frees the static array. Fixed with a `WOOF_IOS`-guarded
  per-session reset at the top of `D_SetupDemoLoop` (free `demoloop` only when
  it's a heap array, then NULL `demoloop`/`demoloop_count`), tracked by a new
  `demoloop_dynamic` flag set right after the parser's `array_push` and
  cleared at every `array_free(demoloop)` — so a static default never inherits
  it and only a heap `m_array` is ever freed. Regression:
  `WaddleUITests/DemoLoopReplayTests` (skips when Doom II isn't provisioned;
  copyrighted, not in CI).
- `src/i_rumble.c` — sixth instance, uncovered while verifying the
  `d_demoloop.c` fix above: with demoloop no longer aborting first, session 2
  reached `I_InitSound` → `I_OAL_CacheSound` → `I_CacheRumble` and
  segfaulted (`EXC_BAD_ACCESS`, NULL deref) inside the FFT peak analysis.
  `InitFFT` caches its allocated `fft.*` buffers keyed by a function-local
  `static int last_rate`. Each session's exit runs `I_ShutdownRumble` →
  `FreeFFT`, which frees and NULLs `fft.setup/in/out/window` but cannot reach
  that guard; on the next session the first cached sound usually has the same
  sample rate, so `last_rate == rate` still held and `InitFFT` skipped
  re-allocating, leaving `CalcPeakFFT` to dereference the freed (NULL)
  `fft.in`/`fft.out`/`fft.window`. Rumble caching runs whenever
  `I_GamepadEnabled()` (i.e. `joy_enable`, on by default) is set, so this
  would have become real users' *new* 2nd-play crash the moment the demoloop
  abort was removed. Fixed by `WOOF_IOS`-guarding the early-return to also
  require `fft.setup` non-NULL (`if (last_rate == rate && fft.setup)`), so a
  session whose buffers were freed re-initialises regardless of the cached
  rate. Zero behaviour change off iOS: `last_rate == rate` only ever holds
  with `fft.setup` already allocated there (FreeFFT runs only at process
  shutdown, after which nothing calls `InitFFT` again).

- `src/mn_menu.c`, `src/woof_ios.c` -- seventh instance (issue #253), the
  first one visible without a crash: `M_Init()` edits its file-scope menu
  tables in place per gamemode -- `MainMenu[readthis] = MainMenu[quitdoom]`,
  `MainDef.numitems--`, `MainDef.y += 8`, `EpiDef.numitems--` (for any
  `gameversion < exe_ultimate`, which Freedoom Phase 2 is), the `ReadDef1`/
  `ReadDef2` rebinding -- and never restores them. Measured on the simulator
  and on a Revyl device: every commercial session took one entry off the main
  menu and shifted it 8 px down, for itself and every later session; a retail
  game played after two commercial sessions showed four main-menu entries (no
  Read This!, no Quit Game) and two of its four episodes. `EngineSmokeTests`
  never saw it because it replays Freedoom Phase 1, and the retail branch is
  the one branch of `M_Init()` with no cumulative edit. Fixed with a
  `WOOF_IOS`-only `MN_ResetMenuTables()` that snapshots `MainMenu`, `MainDef`,
  `EpisodeMenu`, `EpiDef`, `EpiMenuMap`/`EpiMenuEpi`, `EpiCustom`, `NewDef`,
  `ReadMenu1`, `ReadMenu2` (rebound to `M_ExtHelp` by `M_InitExtendedHelp()`
  when a session has `HELP01`), `ReadDef1`, `ReadDef2` and `bigfont_priority`
  on its first call and restores them on every later one (freeing a previous
  UMAPINFO's `strdup`'d episode names first, and the previous session's FON2
  glyphs through `MN_ResetFon2()` in `mn_font.c`, which upstream loads once
  per process and never frees), called from `WoofIOS_Run` before
  `D_DoomMain()`. `w_wad.c`'s lump priority counter, a function-local static
  that kept climbing across sessions, is now file-scope and restarts in
  `W_Close()`, so a remembered priority compares against the list it came
  from. Not inside
  `M_Init()`: `G_ParseMapInfo()` populates the episode tables from the current
  session's UMAPINFO before `M_Init()` runs. A `DEBUG`-gated
  `WoofIOS_DebugMenuGeometry()` exposes the four table values so
  `WaddleUITests/MenuStateAcrossSessionsTests` can assert on them after each
  session; the string ends with `bigfont=<priority>`, which the same test
  requires to be equal across two sessions of one game.

- `src/d_main.c`, `src/woof_ios.c`, `src/woof_ios.h` -- the enumerator for
  this whole section. `WoofIOS_DebugGlobalsCheckpoint()` (no-op unless
  `WADDLE_DEBUG_GLOBALS_DIFF` is in the environment) is called from a
  `WOOF_IOS`-guarded block right after `D_StartGameLoop()`, once per session,
  after every init step and before the first tic. It snapshots the writable
  data sections (`__DATA`/`__DATA_DIRTY` `__data`, `__bss`, `__common`) of the
  image the engine is linked into and, from the second session on, prints a
  `GLOBALDIFF` line per byte range that changed since the previous session.
  `Scripts/globals-diff.py` maps those to variable names through the image's
  DWARF (which is why `Scripts/build-engine.sh` now builds with `-g`) and
  `WaddleUITests/GlobalsDiffProbeTests` drives the sessions. Two sessions of
  one game list state that leaks between sessions; game A then game B lists
  what depends on the previous game -- the list is candidates to read, not a
  verdict: tic counters, RNG state and heap pointers differ legitimately.

- `src/d_main.c`, `src/dsdh_*.c`, `src/deh_strings.c`, `src/st_stuff.c`,
  `src/s_sound.c`, `src/woof_ios.c`/`.h` -- the eighth through fourteenth
  instances (issue #266), found by classifying the list above rather than
  from a crash; `docs/engine-session-globals.md` has every variable and why.
  `D_ResetSessionState()` (d_main.c, called from `WoofIOS_Run`) clears
  `fast_exit`, the wipe state (`wipegamestate`, `screen_wipe_internal`),
  `D_Display`'s memory of the previous frame (its function-local statics are
  hoisted to file scope under `WOOF_IOS` for this), the demo-loop cursor
  including `demoloop_prev` (a pointer into the previous session's loop, read
  by the first `D_DoAdvanceDemo`), and the `autoload_paths` array that
  `PrepareAutoloadPaths` appended to every session. Each `DSDH_*Init` frees its
  `translate` hashmap, which otherwise handed back the previous session's
  indices without growing the freshly reset array (`num_sfx` 811 in session
  1, 700 after: indices past the end of `S_sfx`). `DEH_ResetColorStrings()`
  clears the colorized-message table `ST_InitWidgets` appends to;
  `LoadFacePatches` frees its arrays before appending; `S_ResetSessionMusic()`
  (s_sound.c) restores the pristine `S_music` table and clears `mus_playing`,
  which otherwise made a session that opened on the previous session's last
  track skip starting it. `WoofIOS_DebugSessionStartState()` reports all of it
  as captured at the diff's checkpoint, and
  `WaddleUITests/SessionStartStateTests` requires it to match across sessions.
  What the Freedoom sequence cannot make fail is tracked, not fixed: #268
  (automap, HUD and SDL-object state), #269 (per-session memory growth), #270
  (DEHACKED tables, including `deh_strings.c`'s substitution hash table).

- `src/p_setup.c`, `src/g_compatibility.c`, `src/m_arena.c` -- memory that
  grew with every session (issue #269). `P_Init` reserved five fresh playsim
  arenas each session (352 MB of address space) and never released the last
  five; under `WOOF_IOS` it now clears and reuses them, since nothing is loaded
  at that point and releasing the regions would leave any stale pointer into
  them aimed at unmapped memory. It also frees the previous `seenstate_tab`
  before allocating the next. `G_ParseCompDatabase` frees the previous
  session's records before appending this session's. `M_DebugArenaReservedMB()`
  and `G_DebugCompDatabaseSize()` feed the `arenas=` and `compdb=` fields of
  `WoofIOS_DebugSessionStartState()`. Not fixed: the zone's PU_STATIC blocks,
  about 1.6 MB per session, which need every holder audited first (#269).

- `src/r_data.c`, `src/r_main.c`, `src/r_things.c`, `src/r_tranmap.c`,
  `src/r_voxel.c`, `src/z_zone.c` -- the renderer half of that zone growth
  (#269). Tracing every block's allocation site showed which session-1 zone
  blocks were still alive at session 2's checkpoint: 3021 KB, most of it
  tables the renderer re-allocates every session. Under `WOOF_IOS` each init
  now frees its own previous block before allocating the next:
  `R_InitTextures` (every per-texture table, composites first, since each
  composite names `&texturecomposite[i]` as its zone owner), `R_InitFlats`,
  `R_InitSpriteLumps`, `R_InitColormaps` (the array; the lumps stay cached),
  `R_InitLightTables`, `R_InitTranMap` (the generated maps, never a TRANMAP
  lump), `R_InitSpriteDefs` and `VX_Init` (both remember the sprite count they
  allocated for, because `num_sprites` is already the next session's).  A session can end in `I_Error` part-way through any of these (a malformed
  texture directory, say), so each free is bounded by what was actually
  allocated and zeroed, and every freed global is NULLed before the next
  allocation: `R_InitTextures` zeroes its pointer tables as soon as they
  exist and counts them in `texture_slots`, and `VX_Init` does the same for
  `all_voxels`. `WADDLE_DEBUG_FAIL_TEXTURES` (test-only, `r_data.c`) injects
  that failure; without the bounds, the session after it crashed. What
  survives is 1004 KB, mostly the lump cache. Freeing that in `W_Close` was
  tried and reverted: stale lump pointers from the previous session (the
  automap's `marknums` through the stale `stopped` flag, for one) are passed
  back to `Z_ChangeTag` in session 2, and session 2 died with "an owner is
  required for purgable blocks" and "freed a pointer without ZONEID". The
  leaked blocks were what kept those pointers harmless, so the lump cache waits
  for the holders to be audited (#268, #269). `Z_DebugUnownedKB()` feeds
  `WoofIOS_DebugSessionStartZoneKB()`, which `SessionStartStateTests` bounds
  across two title-only sessions. Checked under AddressSanitizer as well (engine
  and app instrumented; ten sessions across the smoke, menu-table and
  session-start tests, no report); `GlobalsDiffProbeTests` cannot run under it,
  because the probe's whole-section `memcpy` crosses ASan's global redzones.
- `src/am_map.c`, `src/st_widgets.c`, `src/st_stuff.c`, `src/r_data.c`,
  `src/i_input.c`, `src/i_rumble.c`, `src/i_video.c`, `src/woof_ios.c`/`.h`
  -- automap, HUD, rewind and SDL-object state the next session read before
  rewriting it (issue #268). `AM_ResetSessionState()` resets `AM_Start`'s
  `lastlevel`/`lastepisode` (hoisted to file scope under `WOOF_IOS`; while
  they matched, a later game's map of the same number kept the previous map's
  automap bounds and zoom), `stopped` (a session that quit with the automap
  started made the next `AM_Start` run `AM_Stop` on the previous session's
  `marknums`), `AM_ApplyColors`' `first_time` (hoisted likewise), and frees
  `amdef`. `ST_ResetSessionMessages()` clears the previous session's last
  message (and `st_msg_elem`, until Woof 16 removed it); `ST_ResetSessionStatusbar()` NULLs `statusbar`,
  which `I_InitGraphics` read before it was rewritten; `G_ResetRewind(true)`
  drops the previous session's keyframes; `R_ResetSessionColormaps()` frees
  the array `R_InvulMode` wrote through before `R_Init`; `skipblstart` goes
  back to false. `I_ShutdownGamepad`, `I_ShutdownRumble` and
  `I_ShutdownGraphics` now clear the gamepad, rumble state and texture SDL has
  just destroyed; `I_ShutdownRumble` does so on its early return too, when
  gamepad support was switched off after its channels were allocated. `WoofIOS_DebugSessionEntryState()`, captured just before
  `D_DoomMain()`, reports all of it, and `SessionStartStateTests` requires the
  fresh-process string for every session; `WoofIOS_DebugAutomapBounds()`
  backs `testAutomapBoundsAreEachMapsOwn`. Still open in #268: `negonearray`,
  `p_dirty`'s `levels` and `G_ApplyLevelCompatibility`'s saved options.

- `src/deh_main.c`, `src/deh_strings.c`, `src/deh_bex_partimes.c`,
  `src/m_cheat.c`, `src/d_demoloop.c`, `src/woof_ios.c`/`.h` -- DEHACKED
  patches that outlived the session that applied them (issue #270). DEHACKED
  (a PWAD's lump, `-deh`, or the IWAD's own: Freedoom's patches weapons, cheats
  and par times) runs once per session and patches tables in place.
  `DSDH_*Init` already rebuilds states, mobjinfo, sounds and sprites, and
  `S_ResetSessionMusic` restores `S_music`. `DEH_ResetSession()`, called
  from `WoofIOS_Run`, restores the rest from snapshots taken before the
  first session: `weaponinfo`, `clipammo`/`maxammo`, the `deh_*` misc values
  and flags, the cheat sequences (freeing the heap copies a Cheat section
  made), the BEX par times, the default demo loops (`DEH_MUSIC_LUMP`, `HELP2`,
  `DMENUPIC`), the string-replacement table, and the `-deh` file list, whose
  counter `AddDEHFileName` kept in a function-local static. It also clears
  `deh_initialized`, so each session's `DEH_Init` re-reads `-nocheats`.
  `WoofIOS_DebugSessionEntryState()` gains `dehtab dehstr dehfiles cheats pars
  dloop`, and `WoofIOS_DebugDehNow()` reads them live. The app's
  `WADDLE_TEST_DEH_TEXT`/`WADDLE_TEST_DEH_SESSIONS` (debug builds) load a patch
  with `-deh` into chosen sessions, so `SessionStartStateTests` checks a modded
  session followed by a plain one without a PWAD fixture.

- `src/w_wad.c`, `src/st_sbardef.c`, `src/st_widgets.c`, `src/st_stuff.c`,
  `src/hu_crosshair.c`, `src/i_pcsound.c`, `src/z_zone.c` -- the lump cache
  (issue #269). `W_Close` now `Z_Free`s every cached lump and patch, then the
  `lumpcache` array; each session used to orphan the previous session's
  (measured: 14 MB per title-only session with Freedoom). That needed every
  lump-pointer holder that outlives a session reset first. #277 had done the
  automap, `colormaps` and `statusbar`. Under ASan the next one crashed every
  multi-session test: `st_sbardef.c`'s `numberfonts`/`hudfonts` grow per
  session and are searched first-match by name, so `ST_Init` gave session 2
  the first session's fonts and `MN_SetHUFontKerning` read their freed
  glyphs. `ST_ResetSbarDefFonts()` empties both. A static audit added three
  holders no test reaches: `st_time_elem`/`st_cmd_elem` with `UpdateStatusBar`'s
  `oldbarindex` (hoisted under `WOOF_IOS`), the crosshair patch
  (`HU_ResetSessionCrosshair`), and the PC-speaker's current sound (cleared in
  `I_PCS_ShutdownModule`). `Z_DebugOwnedKB()` feeds
  `WoofIOS_DebugSessionStartLumpsKB()`, which `SessionStartStateTests` bounds
  across two title-only sessions.

- `src/p_dirty.c`, `src/g_compatibility.c`, `src/p_setup.c` -- the last of
  issue #268. `P_ResetSessionDirtyLevels()` empties `p_dirty`'s archive of
  completed levels, which grew per session and which
  `P_UnArchiveDirtyArrays` searches first-match by episode and map: a later
  session's rewind on a map of the same number applied an earlier session's
  line and side changes through pointers into a reused world arena.
  `G_ResetSessionCompatibility()` clears `G_ApplyLevelCompatibility`'s
  `restore_comp` (its statics hoisted under `WOOF_IOS`), which otherwise put an
  earlier session's `comp[]` and `demo_version` back on the next session's
  first level. Neither is reachable from a Freedoom session, so two test-only
  hooks reach them: `WADDLE_DEBUG_ARCHIVE_LEVEL` archives the level at the end
  of `P_SetupLevel`, and `WADDLE_DEBUG_COMPDB_MATCH` makes COMPDB's first
  record match. The entry readout gains `dirtylv=` and `compres=`, and
  `WoofIOS_DebugLevelStateNow()` reads them live. `negonearray` needed nothing:
  `R_InitSprites`' stale write lands in its own still-allocated block, at the
  width that block was sized for.

- `src/i_input.c`, `src/mn_menu.c`, `src/woof_ios.c`/`.h` -- input telemetry
  for the in-game debug HUD, added to explain why a Revyl farm device could
  open the menu from the overlay's menu button but neither USE nor the
  virtual stick did anything in it. `WoofIOS_DebugInputState()` composes
  `pad=<name> <virtual|foreign|none> pads=<count>[names] btn=<events> ly=<left
  stick Y> lypk=<its peak since the pad was opened> vly=<value the overlay
  wrote> ab=<axis-derived presses> mv=<menu moves> menu=<item|off>`
  from `WOOF_IOS`-only accessors: `I_DebugGamepadName/ID/Count()` (which
  gamepad `I_OpenGamepad` has open -- the engine reads stick axes only from
  that one, while button events arrive from any gamepad SDL has open),
  `I_DebugGamepadButtonEvents()` (incremented in `UpdateGamepadButtonState`,
  i.e. counted where a gamepad button becomes an engine event; reset per
  session from `WoofIOS_Run`), and `MN_DebugMenuCursor()` (`itemOn` while
  `menuactive`). `WaddleUITests/DebugHUDInputTelemetryTests` parses the
  segment in the simulator; `.revyl/tests/menu-input-telemetry` reads it off
  the device. What the strip showed was `pad=Gamepad foreign pads=2`: the
  phantom MFi controller that GameController reports under automation (and
  on Revyl's farm) is opened by `I_InitGamepad` before the overlay's virtual
  pad exists, and `I_OpenGamepad` keeps its first choice, so the overlay's
  buttons arrived but its axes never did. `I_SelectGamepad()` (`WOOF_IOS`)
  closes the active gamepad and opens a given one; `WoofIOS_SelectTouchGamepad()`
  applies it to the virtual pad, and `OverlayPresenter` calls that whenever
  the overlay is the intended input. See
  `docs/learnings/engine-reads-axes-from-the-first-gamepad.md`.

- `src/m_config.c`, `src/mn_internal.h` -- `M_LoadDefaults` strdup'd a fresh
  block for every string default and never freed the last session's, so all
  12 leaked each session (issue #39). Upstream runs it once per process; the
  guarded `M_InitConfig` above is why it runs every session here. The block
  `M_LoadDefaults`/`M_ParseOption` last allocated is recorded in a `WOOF_IOS`
  field, `default_t.loaded_string`, and freed before the next `strdup`, in
  both functions (`M_ParseOption`'s upstream `free(*dp->location.s)` is
  replaced too). It is NOT `*location.s` that gets freed: `I_SetMidiPlayer` leaves
  `midi_player_string` on a music module's device-list entry and the #116
  migration in `I_InitMusic` sets it to a string literal, so freeing the
  variable would free memory the config code never owned. The field is NULL
  on the first call, which is the first-session guard. A WAD-modified
  default's `orig_default.string` stays allocated because `M_SaveDefaults`
  may still write it out. `M_DebugStringDefaultsLive()` counts at the
  allocation and free sites and feeds `cfgstr=` in
  `WoofIOS_DebugSessionStartState()`, which `SessionStartStateTests` pins
  at 12.

- `src/w_zip.c` -- a `.wad` at the root of a zip or pk3 is decompressed by
  `AddWadInMem` into a `malloc`'d buffer that its lumps point into
  (`lumpinfo_t.data`). Upstream never frees it, and three of the function's
  `I_Error`s (extract failure, short header, bad IWAD/PWAD id) abandon it before
  any lump does. Both leaked once per session here, where `I_Error` ends the
  session rather than the process (issue #38). The three error paths now free
  the buffer first. Once the header checks pass, the buffer goes on a
  `WOOF_IOS` list that `W_ZIP_Close` frees. That also covers the lump-range
  `I_Error` inside the loop, because `W_Close` runs on error and `D_DoomMain`
  registers it before loading any file. Only `W_ReadLump` reads
  `lumpinfo_t.data` (a `memcpy`), so no pointer into the buffer outlives
  `W_Close`. `W_ZIP_DebugWadBuffers()` counts at the malloc and free sites and
  feeds `WoofIOS_DebugZipWadBuffers()` (`zipwads=<live>/<total>`), which
  `SessionStartStateTests.testWadsInsideZipsAreFreedAfterEverySession` reads
  after a valid zip, each of the four error paths and a valid zip again. It
  read 1/1 to 6/6 before the fix. See
  `docs/learnings/i-error-ends-the-session-not-the-process.md`.

- `src/woof_ios.c` / `src/woof_ios.h` (issue #48) -- the touch shim counts
  its writes per control beside the aggregate `touch_event_count`: one slot
  per SDL gamepad button and axis plus the turn injections, incremented at
  the same write sites, reset with the aggregate at session start.
  `WoofIOS_DebugTouchButtonWrites`/`AxisWrites`/`TurnWrites` read them, and
  `WoofIOS_DebugTouchWrites()` renders the non-zero ones as one line
  (`touchWrites: b0:2 turn:0`), shown after a session under
  `WADDLE_DEBUG_INPUT_COUNTS`. `TouchControlsTests` uses it to assert that a
  USE tap wrote SOUTH twice and nothing else, and that a stick drag wrote
  axes and no button -- which the aggregate could never say.

- `src/p_map.c`, `src/p_map.h`, `src/g_game.c`, `src/woof_ios.c` /
  `src/woof_ios.h` (issue #114) -- auto-use. `P_AutoUseLineAhead(player)`
  in p_map.c is `P_UseLines`' traverse without its side effects: it returns
  the first special line within USERANGE that is not behind a blocked
  opening, or NULL, and activates nothing. `G_BuildTiccmd` (WOOF_IOS) probes
  every tic the player is alive in a level and pulses BT_USE when auto-use
  is enabled, the command moves forward, that line differs from the last one
  auto-used, and neither this command nor the previous one carried BT_USE
  (P_PlayerThink uses only on the down edge, so a line remembered under a
  held USE would never be used). The memory clears when nothing is ahead
  (whether or not the player is moving, so turning away re-arms it) and on
  every level load (P_SetupLevel rebuilds lines at reusable addresses), so a
  door is used once per approach rather than toggled every tic, and a switch
  is flipped once. The probe does not classify specials -- P_UseSpecialLine's 151 cases stay the
  one authority -- so a walk-over special ahead costs one silent no-op press.
  `WoofIOS_SetAutoUse(bool)` is the switch (default off; OverlayPresenter
  turns it on with the overlay and off when physical input hides it), and
  `WoofIOS_DebugAutoUseState()` reads `autoUse: enabled=<0|1> presses=<n>`.

- `src/g_game.c`, `src/woof_ios.c` / `src/woof_ios.h` (issue #304) --
  `G_ResetSessionPlayers()` zeroes `players[]` in WoofIOS_Run's per-session
  reset block. Upstream never needs it: G_PlayerReborn preserves `cheats`
  (and the `visitedlevels` pointer) through its memset so cheats last the
  life of the process, and a desktop new game is a new process. Here a new
  game is a new in-process session, so a tester's iddqd was still on at the
  start of a different game and `visitedlevels` pointed into freed memory.
  `G_DebugPlayerCheats()` feeds `pcheats=` in the session-entry readout and
  `WoofIOS_DebugPlayerCheatsNow()`; the `WADDLE_TEST_TYPE_<n>` seam
  (OverlayPresenter) types text through `WoofIOS_InjectChar` so a UI test can
  enter a cheat without a four-finger tap.

- `src/woof_ios.c` / `src/woof_ios.h` (issue #113) -- `WoofIOS_InjectKey(key,
  down)` posts one edge of a held key by Doom key code, and
  `WoofIOS_IsAutomapActive()` exposes `automapactive`. The overlay uses them
  to pan and zoom the automap by touch: the engine's pan and zoom are held
  keys (`AM_Responder` on the arrows, '=' and '-'), so a drag or pinch holds
  the matching keys while the fingers move and releases them when they stop.
  Injected keys are counted per code in `touchWrites` (`k<code>:<n>`), which
  `TouchControlsTests.testAutomapDragPansAndPinchZooms` reads.

- `src/i_video.c`, `src/g_game.c`, `src/g_game.h`, `src/d_main.c` -- the app's
  lifecycle reaches the engine (issue #111). SDL's iOS layer observes UIKit's
  resign-active and did-enter-background notifications itself and turns them
  into `SDL_EVENT_WILL_ENTER_BACKGROUND` (preceded by a `WINDOW_MINIMIZED`,
  which upstream already answers with `screenvisible = false`) and
  `SDL_EVENT_DID_ENTER_BACKGROUND`. Upstream ignores both, so the world kept
  running until iOS froze the process and nothing was written. SDL never
  queues these two (they reach only an event watch, in the notification's
  own call stack -- see
  `docs/learnings/sdl-app-lifecycle-events-are-never-queued.md`), so
  `I_InitGraphics` adds `AppLifecycleWatch` and `I_ShutdownGraphics` removes
  it; the watch hands them to `G_BackgroundPause` (opens the menu in a live level, the
  pause a single-player world actually obeys and the touch overlay can undo)
  and `G_BackgroundSave` (writes `suspend.dsg`, its own file, so neither a
  manual slot nor the level-start autosave is overwritten; skipped at the
  title, in demos, in netgames, with a game action pending or the player
  dead). UIKit posts the notifications while the engine pumps the run loop
  (`I_StartTic`, `I_StartDisplay`), so both run between tics, the same
  boundary `ga_savegame` saves at. `-loadgame 254` loads that file beside upstream's
  255 for `autosave.dsg`; `App/Sources/Library/EngineSaveSlot.swift` maps the
  name. `G_DebugBackgroundCounts` counts at the two sites, never reset, and
  feeds `WoofIOS_DebugBackgroundState()` (`bgsave=<n> bgpause=<n>`), which
  `BackgroundSuspendTests` reads after backgrounding a warped session (1/1)
  and a title-screen one (0/0).

- Re-vendor to 16.0.0 (`1462fadc`, issue #79, 2026-10-03). The patch set
  moved onto a tree with the brightmap refactor (#2924), the colormap and
  lighting rewrites (#2789, #2864), the minimap (#2836), the centered-message
  removal (#2844), the wipe cleanup (#2868) and the savegame overhaul (#2737,
  #2861, #2918). Five files conflicted textually; these are the patches that
  changed, and why:
  - `src/am_map.c` -- `lastlevel`/`lastepisode` are now upstream's per-view
    arrays in `StartView()` (the full automap and the minimap each keep one),
    hoisted as arrays and reset per view in `AM_ResetSessionState()`; the
    `amlvl=` field reports the full view's pair.
  - `src/r_data.c` -- `texturebrightmap` is now an alias of
    `actualtexturebrightmap` or `notexturebrightmap`; the per-session free
    covers the two real tables and NULLs the alias. `colormaps[i]` are no
    longer cached lumps (which `W_Close` frees) but rows of one `Z_Malloc`'d
    block whose start is `colormaps[0]`, so `R_ResetSessionColormaps()` frees
    that block before the array, and `R_InitColormaps()` calls it too.
  - `src/r_main.c` -- `zlightindex`/`scalelightindex` are gone;
    `zlightoffset` and `scalelightoffset` are each a row-pointer array over one
    block whose start is row 0, and are freed as such.
  - `src/st_stuff.c` -- upstream made `UpdateStatusBar` public as
    `ST_UpdateStatusBar(void)`; the hoisted `oldbarindex` stays.
  - `src/st_widgets.c`, `src/woof_ios.c`/`.h` -- `st_msg_elem` no longer
    exists (#2844), so `ST_ResetSessionMessages()` only clears the message, the
    `ST_DebugMessageElemSet()` seam is gone and the entry readout's field is
    `msg=<left>` rather than `msg=<left>/<elem>`; `SessionStartStateTests`'
    fresh-process literal changed with it.
  - `src/d_main.c` -- `wipe_Invalid` is `wipe_Default` now.
  - `src/v_palette.c` (new upstream file, new patch) -- `InitPlaypal()`
    allocates one palette table per gamma level for each of two palettes every
    session and nothing frees them; under `WOOF_IOS` the previous session's are
    freed first. The lump behind `playpal->data` is the lump cache's, which
    `W_Close` already frees.
  - `src/g_game.h` -- `G_SaveGameName`/`G_MBFSaveGameName` take `(slot, page)`
    now. The suspend save keeps its own name through `SaveGameName("suspend.dsg")`,
    and `-loadgame 254`/`255` in `d_main.c` are unchanged. Saves are compressed
    JSON since #2737; the app reads only a save's file name, never its contents
    (`App/Sources/Library/EngineSaveSlot.swift`).

- `third-party/miniz/miniz.c`, `third-party/miniz/miniz.h` -- miniz 3.1.2
  dropped over the 3.1.1 upstream Woof still vendors (issue #79, step 4).
  Woof's copy was byte-identical to the 3.1.1 release, so this is the
  upstream 3.1.2 release unmodified: a guard against a `code_len == 0`
  infinite loop in `tinfl_decompress`, an overflow check on the zip central
  directory offset, and parameter validation in the PNG writer. miniz parses
  every zip and pk3 the user imports and inflates every compressed-nodes map,
  so it is the untrusted-input surface; `Scripts/check-deps-current.sh` reads
  `MZ_VERSION` from the header and reports it current. Drop this patch when a
  Woof pin carries 3.1.2 or later (the file will then be identical and the
  re-vendor merge resolves it on its own).

- `src/p_setup.c`, `src/woof_ios.c` (issue #79) -- `P_SetupLevel` records the
  node and blockmap format of the level it just set up (`last_bsp_format`,
  `last_bmap_format`, reset per session by `P_ResetSessionLevelFormats()`),
  and `WoofIOS_DebugLevelStateNow()` reports them as `nodes=<DoomBSP|ZNOD|...>
  bmap=<lump|BoomBlockmap|XBM1>` after the existing fields. This is how
  `WaddleUITests/CompressedNodesTests` proves that `Fixtures/freedoom-e1m1-znod.wad`
  (Freedoom's E1M1 with ZDBSP-compressed nodes) actually went through
  `P_LoadNodes_ZDBSP`'s inflate path (upstream `cc1d13e9`) and, with its
  BLOCKMAP lump emptied, through the blockmap-presence check (`42470994`),
  rather than merely not crashing: the IWAD's own E1M1 would read `DoomBSP`.

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

The patch set is 59 files over 53 commits, most of which also edit `App/`, so
replaying commits one by one is no longer the cheap path; a three-way merge in
a scratch clone of upstream is. The 2026-10-03 move (111 upstream commits, 32
files touched on both sides) produced five textual conflicts this way. See
`docs/learnings/revendor-woof-with-a-three-way-merge.md` for the traps.

1. Note the current pristine vendor commit `<old-pristine>` (the latest
   `engine: vendor Woof! ...` commit) and record the patched file set:
   `git diff --name-status <old-pristine>..main -- Engine/woof`.
2. In a scratch clone of upstream: `git checkout -b patches <old-pin>`, then
   `rsync -a --delete --exclude .git Engine/woof/ <clone>/`, commit; then
   `git checkout -b merged <new-pin>` and `git merge patches`. Resolve the
   conflicts. Then read every `WOOF_IOS` block in every file upstream touched,
   not only the conflicted ones: a per-session free mirrors an allocation
   upstream may have replaced without a textual conflict (brightmaps,
   colormaps and light tables all did in 2026-10), and grep new upstream files
   for allocations at init that need the same treatment (`v_palette.c` did).
3. Update `WOOF_COMMIT` in `Scripts/vendor-woof.sh`, run it (this wipes the
   tree) and commit the pristine tree as `engine: vendor Woof! master <commit>`.
4. `rsync -a --delete --exclude .git <clone>/ Engine/woof/`, then
   `git checkout --` any file that differs only between the tarball and a git
   checkout (`toolsrc/defswani.dat`, line endings). Compare
   `git diff --name-status <new-pristine> -- Engine/woof` with the list from
   step 1: every file must still be there, plus whatever the bump added, and
   `src/woof_ios.c`, `src/woof_ios.h` and `src/i_easmusic.c` must still be
   pure additions. A file that dropped out is a lost patch no test notices.
5. `cmake --build Vendor/build/woof-iphoneos --target woof -- -k 0` collects
   every compile error in one pass (renamed identifiers surface here, not in
   the merge); then `Scripts/build-engine.sh`.
6. Run the unit suite and the multi-session UI suites (`EngineSmokeTests`,
   `SessionStartStateTests`, `MenuStateAcrossSessionsTests`,
   `BackgroundSuspendTests`, `QuitGameTests`, `TouchControlsTests`): the unit
   suite links the framework but never starts a second session, which is where
   most of the patch set lives. Then update this file's pin and patch notes,
   `CLAUDE.md`, `README.md` and `docs/learnings/woof-engine-pin.md`.

## When the pins get looked at

Renovate covers none of the native pins (`renovate.json` says so), so the
schedule is this repository's own (issue #79):

- **Weekly, automatically.** `.github/workflows/cold-build.yml` runs
  `Scripts/check-deps-current.sh` every Monday, after rebuilding every
  dependency from source, and writes the report to the job summary. It
  reports; it does not gate. A pin it cannot determine fails the step, so a
  broken query is never read as "current".
- **Immediately, by hand,** on any upstream fix touching WAD, zip/pk3 or map
  parsing in Woof or miniz: that is the untrusted-input surface
  (`App/Sources/Library/LoadoutArguments.swift` hands imported files straight
  to the engine). Woof's commit log and miniz's `ChangeLog.md` are where such
  fixes show; `cc1d13e9`, `42470994` and miniz 3.1.2 were all of this kind.
- **How each pin moves.** Woof: the procedure above. SDL, OpenAL Soft, SONiVOX
  and the libsndfile stack: edit the tag in `Scripts/build-deps.sh`; any local
  fix lives in `Scripts/patches/<dep>/` and the build refuses a patch that no
  longer applies either way. Freedoom: `FREEDOOM_VERSION` in
  `Scripts/fetch-freedoom.sh`, SHA-256 verified. The libraries under
  `third-party/`: only with the Woof pin, except where this file records a
  local drop-in (miniz, above). Every bump except Freedoom's invalidates the
  engine fingerprint, so `Scripts/build-engine.sh` must be re-run and CI
  builds cold; `Scripts/engine-fingerprint.sh` hashes `Engine/woof`, the two
  build scripts and `Scripts/patches/`, and nothing Freedoom touches, so a
  Freedoom bump needs only `Scripts/fetch-freedoom.sh` again.
