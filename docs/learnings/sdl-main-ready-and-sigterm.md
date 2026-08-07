# SDL startup and signal handling inside the SwiftUI-owned app

Two non-negotiables for hosting the engine under a SwiftUI app that owns the
process:

- **`SDL_SetMainReady()` must be called before the first `SDL_Init`.** SDL's
  normal entry point is bypassed when SwiftUI owns `main`, and without this call
  initialisation fails in ways that do not name the cause.
- **`SIGTERM` is `SIG_IGN`'d for the duration of an engine session.**
  `xcodebuild` sends stray `SIGTERM`s that SDL converts into quit events, which
  ends the session mid-test and looks like an engine crash.

**Provenance:** Plan 1 Task 8 (SwiftUI-owned architecture) and Task 10, where
the stray-`SIGTERM` behaviour was root-caused after it presented as random test
kills.
