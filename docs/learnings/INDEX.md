# Learnings Index

One file per hard-won fact. Add an entry here in the same PR that adds the file —
`Scripts/check-substrate.sh` enforces the bijection.

- [The Woof pin is a master commit, not a release tag](woof-engine-pin.md) — why `woof_15.3.0` must never be used
- [Engine resource paths are load-bearing and non-obvious](engine-resource-layout.md) — woof.pk3, GameData/, and the `-save` flag
- [SDL startup and signal handling inside the SwiftUI-owned app](sdl-main-ready-and-sigterm.md) — SDL_SetMainReady and the SIGTERM bracket
- [Orientation support needs both halves, or it silently does nothing](orientation-needs-both-halves.md) — Info.plist *and* SDL_HINT_ORIENTATIONS
- [Engine console output does not reach `log stream`](engine-console-output-is-invisible.md) — use xcresult stdout or --console-pty
- [Every injected keydown must be paired with a keyup](soft-keyboard-keydown-keyup-pairing.md) — or cheat letters latch and the player walks forever
- [iOS 26 TabView tab-bar buttons ignore accessibility identifiers](ios26-tabview-accessibility.md) — address tabs by label, panes by identifier
- [iOS 26 List swipe actions change shape with row height](ios26-list-swipe-actions-row-height.md) — the stock idiom, already bisected; do not re-investigate
- [SwiftUI `Menu` cannot render `Slider` rows](swiftui-menu-cannot-host-sliders.md) — why tuning lives in the Control Feel sheet
- [Gesture recognizers do not fire inside SDL's own UIWindow](sdl-window-gesture-recognizers.md) — use responder-chain touches instead
- [Setting up a second worktree has two traps](worktree-setup-traps.md) — the Vendor symlink and the stale CMakeCache
- [Simulator hazards that produce misleading test results](simulator-test-hazards.md) — rotation, screenshot orientation, and RealWADTests fixtures
- [A test that builds a git fixture inherits the developer's signing config](git-fixtures-inherit-signing-config.md) — `tag.gpgSign` surfaces as `fatal: no tag message?`
- [Masking a query's exit status makes a guard fail open](masked-exit-status-fails-open.md) — three times now; test the status, then rule on empty output separately
- [An empty simulator list means infrastructure, not a bad pin](simulator-enumeration-race.md) — CoreSimulator can fail to enumerate anything on a cold runner; `Scripts/check-simulator-available.sh` is the check
