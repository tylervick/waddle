# Orientation support needs both halves, or it silently does nothing

Supporting rotation requires **both**:

1. The orientation entries in `Info.plist`, and
2. `SDL_HINT_ORIENTATIONS` set in `woof_ios.c`.

With the plist alone everything *looks* correct and rotation is silently
ignored: SDL's `UIKit_GetSupportedOrientations` falls back to the game window's
aspect ratio, and because that window is non-resizable and landscape, every
session is pinned to landscape.

**Provenance:** Plan 4 Task 7b, commit `a9acd51`. The plist-only version was
believed correct until the hint was found by reading SDL's source.
