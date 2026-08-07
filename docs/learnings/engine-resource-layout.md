# Engine resource paths are load-bearing and non-obvious

Three placements the engine and Xcode both depend on:

- **`woof.pk3` sits at the app bundle root.** The engine finds it via
  `SDL_GetBasePath()` with no override, so it cannot be nested.
- **IWADs live in `GameData/`.** The Xcode folder reference must *never* be
  renamed to "Resources" — a top-level folder reference by that name triggers an
  Xcode codesign bug that breaks `simctl install`.
- **The save flag is `-save <dir>`, not `-savedir`.** Saves are per-preset, at
  `Documents/Saves/<preset-id>/`.

`-complevel` accepts exactly `vanilla`, `boom`, `mbf`, `mbf21`.

**Provenance:** Plan 1 Tasks 8 and 9. The "Resources" naming trap cost a full
debugging cycle; the `-savedir` spelling shipped in the design spec and had to
be corrected in commit `b85aea6`.
