# A leak can be what keeps a stale pointer safe

Found 2026-09-23 while fixing the per-session zone growth in #269.

Every engine session used to orphan the previous session's zone blocks: the
cached lumps and patches (`lumpcache`) and the renderer's tables. Freeing the
lump cache in `W_Close` was the obvious one-line fix, and it broke session 2
at once. The engine died with `I_Error("freed a pointer without ZONEID")` on
one run and `I_Error("an owner is required for purgable blocks")` on the next.
Code that kept a lump pointer from session 1 passed it back to `Z_ChangeTag`
or `Z_Free` in session 2. For example, the automap's `marknums` are reached
through `AM_Start` → `AM_Stop` → `AM_unloadPics` when the stale `stopped` flag
says the automap is running. While the old blocks leaked, those pointers aimed
at live memory and nothing noticed. Once freed, they aimed at a header the
zone had reused.

So before freeing anything the previous session allocated, find every holder
of it that outlives the session. The classification in
`docs/engine-session-globals.md` says which statics are rewritten before use.
Anything it marks as a follow-up is a holder that is *not*. The safe unit is
the allocation the init function itself re-assigns: free the previous block
right before the new one replaces it, as `R_InitTextures` and friends now do.
Leave anything reachable from elsewhere until those holders are reset.

Two ways the failure hides:

- **The engine's error text never reaches the logs you would read first.**
  `I_Error` shows an SDL message box, so the test only reports "engine never
  returned to the launcher". The text is in the UI hierarchy: grep the
  session log's accessibility dump for `StaticText` labels, or read the
  xcresult's failure-time hierarchy.
- **The session log is capped at 1,000,000 bytes**, and the UI-test runner's
  accessibility chatter fills it, so a backtrace printed to stderr can be
  missing from it. Write diagnostics to a file under `getenv("HOME")` (the
  app's data container) and read it with
  `xcrun simctl get_app_container <udid> com.tylervick.waddle data`.

AddressSanitizer is the way to check a free like this across sessions: add
`-fsanitize=address -fno-omit-frame-pointer` to the engine's
`CMAKE_C_FLAGS_RELEASE` in `Scripts/build-engine.sh` (temporarily), and pass
`-enableAddressSanitizer YES` to `xcodebuild`. The report is in the xcresult
diagnostics (`StandardOutputAndStandardError-com.tylervick.waddle.txt`), not
the session log. `GlobalsDiffProbeTests` cannot run under ASan, because the
probe's whole-section `memcpy` crosses the sanitizer's global redzones and
reports a global-buffer-overflow in `WoofIOS_DebugGlobalsCheckpoint` itself.
