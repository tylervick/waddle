# Vendored Woof! provenance

- Upstream: https://github.com/fabiangreffrath/woof
- Tag: `woof_15.3.0`
- Vendored by: `Scripts/vendor-woof.sh`

## iOS patch set

All iOS changes are committed directly to `Engine/woof/` with commit
subjects prefixed `engine:`. Keep the patch set minimal.

Current patches:
- `src/CMakeLists.txt` — on iOS, build `woof` as a STATIC library, exclude
  `i_main.c` and the `woof-setup` tool, define `WOOF_IOS`.
- `src/i_exit.c` — on iOS, `I_SafeExit()` unwinds to the host app via
  `WoofIOS_ExitUnwind()` instead of calling `exit()`, and resets its
  priority counter so a second engine session can run exit handlers again.
- `src/woof_ios.h` / `src/woof_ios.c` — iOS entry point (`WoofIOS_Run`)
  replacing `i_main.c`, plus `WoofIOS_RequestQuit`.

## Updating to a new upstream release

1. `git log --oneline -- Engine/woof` and note the `engine:` patch commits.
2. Update `WOOF_TAG` in `Scripts/vendor-woof.sh`, run it (this wipes the tree).
3. Commit the new pristine tree as `engine: vendor Woof! <tag>`.
4. Re-apply each patch commit with `git cherry-pick` (or by hand), resolving
   conflicts against the new tree.
5. Rebuild and re-run the simulator smoke test (Task 10) before merging.
