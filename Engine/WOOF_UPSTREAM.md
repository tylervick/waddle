# Vendored Woof! provenance

- Upstream: https://github.com/fabiangreffrath/woof
- Pin: master commit `798acebd52b6cc1623dde556d3e3a236a25a41d1` (2026-07-12,
  SDL3 ≥ 3.4 tree; reports version 15.2.0)
- Vendored by: `Scripts/vendor-woof.sh`

Previously pinned to tag `woof_15.3.0`, which turned out to be the
SDL2-era tree — incompatible with the SDL3-only iOS dependency set
built in Task 4. Re-pinned to the SDL3 master commit above (plan
corrected in ae876c9).

## iOS patch set

All iOS changes are committed directly to `Engine/woof/` with commit
subjects prefixed `engine:`. Keep the patch set minimal.

Current patches:
- (none yet — pristine tree; Task 5 patches land in follow-up commits)

## Updating to a new upstream pin

1. `git log --oneline -- Engine/woof` and note the `engine:` patch commits.
2. Update `WOOF_COMMIT` in `Scripts/vendor-woof.sh`, run it (this wipes the
   tree).
3. Commit the new pristine tree as `engine: vendor Woof! <commit>`.
4. Re-apply each patch commit with `git cherry-pick` (or by hand), resolving
   conflicts against the new tree.
5. Rebuild and re-run the simulator smoke test (Task 10) before merging.
