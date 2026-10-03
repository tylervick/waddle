# Re-vendoring Woof is a three-way merge, and "auto-merged" is not "correct"

The first pin move (798acebd → 1462fadc, 2026-10-03, issue #79) hit three traps
that `Engine/WOOF_UPSTREAM.md`'s original "cherry-pick each patch commit"
procedure did not anticipate. The procedure there now describes what worked.

**1. Replaying patch commits does not scale; merging the patch set does.**
The iOS patch set had grown to 59 files over 53 commits, most of which also
edit `App/`, and 32 of those files had moved upstream too. Cherry-picking would
have been 53 conflict rounds against a tree the early commits never saw.
Instead: in a scratch clone of upstream, branch at the OLD pin, copy
`Engine/woof/` over it (`rsync -a --delete --exclude .git`), commit, and
`git merge` that onto the NEW pin. Git then has the real base, so the 32
overlapping files produced five textual conflicts, all under 30 lines.

**2. A clean auto-merge can still be wrong.** Every `WOOF_IOS` per-session free
mirrors an upstream allocation. Upstream replaced three of those allocations
without touching the lines the patch added, so git merged them silently:

- `texturebrightmap` became an alias of two new tables
  (`actualtexturebrightmap`, `notexturebrightmap`); freeing the alias would have
  freed one table and leaked the other.
- `colormaps[i]` stopped being cached lumps (which `W_Close` frees) and became
  rows of one `Z_Malloc`'d block; the old free released only the row array.
- `zlightindex`/`scalelightindex` vanished and the two remaining light tables
  became row-pointer arrays over one block each.

A new upstream file (`v_palette.c`) also allocates per session with nothing
freeing it. So after the merge, read every `WOOF_IOS` block in every file
upstream touched -- not only the conflicted ones -- next to the allocation it
mirrors, and `grep` new upstream files for `Z_Malloc`/`malloc` at init.

**3. Two kinds of noise look like lost or extra patches.** The tarball
`Scripts/vendor-woof.sh` unpacks and a git checkout of the same commit differ
in line endings for `toolsrc/defswani.dat`, so the copied tree shows a change
there that is not a patch; `git checkout --` it. And the compiler, not the
merge, finds the renamed identifiers (`wipe_Invalid` → `wipe_Default`, a
removed `st_msg_elem`): compile with `cmake --build <dir> --target woof -- -k 0`
to collect every error in one pass before running `Scripts/build-engine.sh`.

**The check that matters:** `git diff --name-status <new-pristine> -- Engine/woof`
must list the same files as `git diff --name-status <old-pristine>..<old-head>
-- Engine/woof` did, plus any patch the bump itself added. A file that dropped
out is a patch lost in the merge, and no test in this repository would notice.
