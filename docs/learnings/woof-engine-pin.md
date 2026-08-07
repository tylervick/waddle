# The Woof pin is a master commit, not a release tag

`Engine/woof` is pinned to master `798acebd`. Upstream Woof! has **no SDL3
release tag** — every published tag, including `woof_15.3.0`, is SDL2-era and
will not build against this project's SDL3 vendoring. The engine's version
string still reports "Woof 15.2.0"; that is expected and not evidence of a
wrong pin.

**What to do instead:** treat the pin as a commit SHA. Bumping it means
choosing a newer master commit and re-running `Scripts/vendor-woof.sh`, never
resolving a tag.

**Provenance:** Plan 1 Task 5, which was blocked mid-task by exactly this —
`woof_15.3.0` was tried first and had to be re-pinned to master.
