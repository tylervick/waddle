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
files with the *primary* checkout's path hardcoded, and `mise run build-engine`
then fails. Fix: `rm -rf Vendor/build` and rebuild. Confirm first that it is not
a symlink to the other worktree.

**Provenance:** touch-tuning worktree 2026-07-18 (trap 1), soft-keyboard
worktree 2026-07-21 (trap 2).
