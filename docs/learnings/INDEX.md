# Learnings Index

One file per hard-won fact. Add an entry here in the same PR that adds the file —
`Scripts/check-substrate.sh` enforces the bijection.

- [The Woof pin is a master commit, not a release tag](woof-engine-pin.md) — why `woof_15.3.0` must never be used
- [Engine resource paths are load-bearing and non-obvious](engine-resource-layout.md) — woof.pk3, GameData/, and the `-save` flag
- [SDL startup and signal handling inside the SwiftUI-owned app](sdl-main-ready-and-sigterm.md) — SDL_SetMainReady and the SIGTERM bracket
- [Orientation support needs both halves, or it silently does nothing](orientation-needs-both-halves.md) — Info.plist *and* SDL_HINT_ORIENTATIONS
- [Engine console output does not reach `log stream`](engine-console-output-is-invisible.md) — use xcresult stdout or --console-pty
- [Every injected keydown must be paired with a keyup](soft-keyboard-keydown-keyup-pairing.md) — or cheat letters latch and the player walks forever
