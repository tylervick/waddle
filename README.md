# BoomBox (working name)

A free, open-source Doom source-port app for iPhone and iPad, built on
[Woof!](https://github.com/fabiangreffrath/woof) (Boom/MBF21 compatibility).
Bundles [Freedoom](https://freedoom.github.io/); users import their own WADs.

Licensed under the GNU GPL v2 (see COPYING). Freedoom content is
BSD-licensed (see its accompanying COPYING file).

## Building

Requirements: Xcode 26.2+, and the CLI tools `cmake`, `ninja`, and
`xcodegen`. The pinned versions are in `mise.toml` — with
[mise](https://mise.jdx.dev) installed, `mise install` fetches them all;
otherwise `brew install cmake ninja xcodegen` works too (unpinned).

```sh
mise run bootstrap   # build deps + engine, fetch Freedoom, generate Xcode project
```

Or run the steps individually:

```sh
Scripts/build-deps.sh          # SDL3 + OpenAL Soft static libs (device + simulator)
Scripts/build-engine.sh        # Woof! static lib + WoofEngine.xcframework; stages woof.pk3
Scripts/fetch-freedoom.sh      # Freedoom WADs into App/Resources/GameData
Scripts/generate-build-info.sh # seeds App/Sources/Generated/ (gitignored) so xcodegen's
                                # static file scan picks it up; regenerated every build after
cd App && xcodegen generate    # generate BoomBox.xcodeproj
```

Then build/run the `BoomBox` scheme in Xcode, or from the command line
(`mise run test` is a shortcut for this):

```sh
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

`test` (not `build`) also runs the engine boot/quit/relaunch smoke check on
the simulator — the fastest way to confirm a from-scratch build actually
works end to end, not just compiles.

### Deviations worth knowing about

- **The Woof! source is committed (vendored) — do not run
  `Scripts/vendor-woof.sh` as part of a normal build.** It re-downloads the
  pinned upstream tree and clobbers the committed iOS patch set; it exists
  only for maintainers updating the engine pin, following the procedure in
  `Engine/WOOF_UPSTREAM.md`.
- **Woof! is pinned to a `master` commit, not a release tag.**
  `Scripts/vendor-woof.sh` hardcodes `WOOF_COMMIT` to a specific commit on
  the SDL3-based tree (it reports itself as "Woof 15.2.0"). The newer-looking
  `woof_15.3.0` tag is actually the older SDL2-era tree and does not build
  against this project's SDL3-only iOS dependencies. See
  `Engine/WOOF_UPSTREAM.md` for the exact commit, provenance, and the full
  iOS patch set carried on top of it.
- **`woof.pk3` is staged at the app bundle root**
  (`App/Resources/woof.pk3`), *not* under `GameData/` — Woof! locates it via
  `SDL_GetBasePath()`, which resolves to the bundle root on iOS, and there
  is no command-line override for that search. The bundled IWADs
  (`freedoom1.wad`, `freedoom2.wad`, fetched by `Scripts/fetch-freedoom.sh`)
  live under `App/Resources/GameData/` instead and are passed to the engine
  via an explicit `-iwad` path, so their location is unconstrained.
  `App/project.yml`'s folder reference is deliberately named `GameData`
  rather than `Resources`: a literal `Resources` folder reference makes
  Xcode emit macOS-style codesign rules that break `simctl install` on an
  iOS target.
- Engine sessions are launched with `-save <dir>` (not `-savedir`), pointing
  at a per-loadout directory (`Documents/Saves/<loadout-id>/`) so each
  loadout keeps its own save games, even loadouts that share an IWAD.

## WAD library

Import WADs three ways: the in-app Import button, "Share → BoomBox" from
another app, or drop files into the app's folder in the Files app (adopted
on next launch). IWADs, PWADs, `.deh`/`.bex` patches, and zips containing
any of those all work; zips are recursed into and duplicates are deduped by
content hash. Files that fail to import (bad header, unsupported type,
etc.) are never silently deleted — they're moved to `Documents/Import
Failed/`, visible and recoverable from the Files app. Build **loadouts**
(one IWAD + ordered PWADs/patches); each loadout keeps its own save games.
Freedoom Phase 1+2 are bundled and pre-wired as loadouts.

## Controls

- **Touch:** left side of the screen is a floating movement stick. On-screen
  buttons: FIRE, USE, weapon prev/next, automap (MAP), and menu (≡). Two
  touch control schemes are available from the gear menu on the Play tab
  ("Touch Controls: Classic / Modern", persisted across launches):
  - **Classic** (default): the stick's horizontal axis turns, vertical axis
    moves forward/back — no strafe, matching how classic WADs expect to be
    played. The right side of the screen has no drag gesture; it only hosts
    buttons.
  - **Modern:** twin-stick strafe — the stick moves in all directions
    (forward/back + strafe), and dragging on the right side turns. The
    right side shows the same base/knob visuals as the movement stick while
    dragging.

  The overlay drives a virtual gamepad, so all bindings are remappable in
  Woof!'s own setup menu.
- **Control feel tuning:** the same gear menu has a "Control Feel…" sheet
  with three persisted sliders (values are read when a session's overlay
  installs, so mid-session changes apply to the next session):
  - **Turn Speed** (0.25–3.0, default 1.0): multiplies the classic scheme's
    stick turn and the modern scheme's drag-to-turn sensitivity.
  - **Stick Dead Zone** (0.05–0.4, default 0.2): fraction of the movement
    stick's radius that ignores small wobbles before movement registers.
  - **Move Sensitivity** (0.5–1.5, default 1.0): scales forward/back and
    strafe output.

  With "Show Debug Info" on, the in-session HUD shows the effective values
  (`turn`/`dz`/`move`) — see `docs/manual-testing.md` for the on-device
  tuning procedure.
- **Controllers:** Xbox/PlayStation/Switch/MFi via GameController — the
  touch overlay hides automatically while one is connected.
- **Keyboard & mouse:** hardware keyboards hide the overlay; mouse look
  works on iPad (indirect input events are enabled).
- **Debug HUD:** the same gear menu has a "Show Debug Info" toggle
  (persisted) that adds a build-stamp footer on the Play tab and a live
  commit/scheme/touch-event/trigger-value overlay during engine sessions —
  see `docs/manual-testing.md` for what each field means.

### Real-WAD test matrix

`App/UITests/RealWADTests.swift` verifies vanilla/Boom/MBF21 content against
real community WADs, plus a negative case built from a synthetic,
unrecognized-IWAD fixture that `Scripts/provision-test-wads.sh` generates
itself — not a real wrong-IWAD-pairing WAD. (Woof never auto-warps into a
level without an explicit `-warp` flag, which this app never passes, so a
real mismatched IWAD/PWAD pairing just idles harmlessly on the title screen
instead of erroring; an unrecognized IWAD is the reliable way to make the
engine actually fail.) The vanilla/Boom/MBF21 cases expect the real WADs in
`~/Downloads/doom-test-wads/` (see the script header) provisioned via
`Scripts/provision-test-wads.sh` after installing the app on the simulator;
without them, only that test class fails.
