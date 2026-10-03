# The Woof pin is a master commit, not a release tag

`Engine/woof` is pinned to master `1462fadc` (2026-10-01, reports "Woof
16.0.0"; before 2026-10-03 it was `798acebd`, which reported 15.2.0). Upstream
Woof! has **no SDL3 release tag** — every published tag, including
`woof_15.3.0`, is SDL2-era and will not build against this project's SDL3
vendoring. A version string that does not match any upstream tag is expected
and not evidence of a wrong pin.

**What to do instead:** treat the pin as a commit SHA. Bumping it means
choosing a newer master commit and following the procedure in
`Engine/WOOF_UPSTREAM.md` (a three-way merge of the iOS patch set, see
`docs/learnings/revendor-woof-with-a-three-way-merge.md`), never resolving a tag and never
running `Scripts/vendor-woof.sh` on its own, which wipes the patches.

**Provenance:** Plan 1 Task 5, which was blocked mid-task by exactly this —
`woof_15.3.0` was tried first and had to be re-pinned to master.
