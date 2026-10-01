# Setting up a second worktree has two traps

Setup is: symlink `Vendor` and `App/Resources/GameData` from the primary
checkout, copy `woof.pk3`, then run `Scripts/generate-build-info.sh` and
`xcodegen`.

**Trap 1 — `.gitignore` does not hide a `Vendor` symlink.** The `Vendor/`
pattern does not match a symlink, because trailing-slash patterns do not match
symlinks. Hide it through
`$(git rev-parse --git-common-dir)/info/exclude` — note *common*-dir: the
per-worktree git dir has no `info/` and its exclude file is never read.

**Trap 2 — the copied `Vendor/build` cache points at the other checkout.** A
fresh worktree inherits gitignored `Vendor/build/` containing `CMakeCache.txt`
files with the *primary* checkout's path hardcoded, and `cmake` refuses to
configure on top of them. `Scripts/ensure-native-cmake-cache.sh` is the check:
`build-deps.sh` and `build-engine.sh` run it on each build directory right
before configuring, and it clears any whose cache names another directory
(compared physically, so a `Vendor` symlinked at the primary checkout keeps
its shared caches). Nothing to do by hand; the note it prints is the only
sign. A setup-time `rm -rf Vendor/build` (`orca.yaml`) was not enough, because
Orca re-seeds the directory after the hook has run (issue #72).

**Provenance:** touch-tuning worktree 2026-07-18 (trap 1), soft-keyboard
worktree 2026-07-21 (trap 2).
