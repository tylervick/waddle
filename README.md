# BoomBox (working name)

A free, open-source Doom source-port app for iPhone and iPad, built on
[Woof!](https://github.com/fabiangreffrath/woof) (Boom/MBF21 compatibility).
Bundles [Freedoom](https://freedoom.github.io/); users import their own WADs.

Licensed under the GNU GPL v2 (see COPYING). Freedoom content is
BSD-licensed (see its accompanying COPYING file).

## Building

Requirements: Xcode 26.2+, Homebrew (`brew install cmake ninja xcodegen`).

```sh
Scripts/build-deps.sh       # SDL3 + OpenAL Soft static libs (device + simulator)
Scripts/build-engine.sh     # Woof! static lib + WoofEngine.xcframework; stages woof.pk3
Scripts/fetch-freedoom.sh   # Freedoom WADs into App/Resources/GameData
cd App && xcodegen generate # generate BoomBox.xcodeproj
```

Then build/run the `BoomBox` scheme in Xcode, or from the command line:

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
  at a per-IWAD directory under the app's Documents folder.
