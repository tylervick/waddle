# Under `pipefail`, a pipeline into `grep -q` or `head` fails when it MATCHES

`set -o pipefail` reports the first non-zero status in a pipeline. `grep -q`
and `head -n` exit as soon as they have what they need. If the producer still
has data to write when that happens, it takes SIGPIPE and dies with 141, and
`pipefail` surfaces that 141 as pipeline failure.

The result is inverted, which is what makes it vicious:

```bash
set -euo pipefail
if ! git log --oneline -20 | grep -q "some commit"; then
    die "not found"     # runs when the commit IS present
fi
```

| Case | Pipeline status | Verdict |
| --- | --- | --- |
| pattern **present** | **141** (SIGPIPE) | reads as failure |
| pattern **absent** | 1 | reads as "checked, absent" |

A guard written this way refuses the healthy state and passes the broken one.

## It is not `grep -q` — it is "producer still writing"

Measured on this machine:

| Producer | Output size | Match early? | Status |
| --- | --- | --- | --- |
| `echo` | ~200 B | yes | 0 — safe |
| `echo` | ~200 KB | yes | **141** |
| `seq` (streaming) | large | yes | **141** |
| any | any | no | 1 |

Two independent triggers, and either is enough:

- **The producer streams.** `git log` emits commit by commit, so 20 short lines
  is plenty — it was still writing when `grep -q` exited. Size is irrelevant here.
- **Output exceeds the pipe buffer** (~64 KB on macOS). A single `echo` that
  fits is written atomically and finishes before the consumer exits, so it is
  safe; the same `echo` past the buffer blocks mid-write and then takes SIGPIPE.

That second row is the trap in this repo's test suites. `echo "$out" | grep -q ...`
appears throughout `Scripts/test-*.sh` and is safe **only because `$out` is
small**. Nothing marks that dependency, so a fixture whose captured output grows
past 64 KB turns its assertions inside out — passing when they should fail.

## The fix: do not pipe into the early-exiting consumer

```bash
recent_log="$(git log --oneline -20)"      # capture, then match
case "$recent_log" in
    *"some commit"*) ;;
    *) die "not found" ;;
esac
```

For `find ... | head -1`, use `find ... -print -quit` — it stops at the first
hit with no pipe at all. For anything else, capture into a variable and match
with `case`/`[[ ]]`.

Do **not** reach for `|| true` here. That silences the 141 and the real errors
together, which is the defect in
`docs/learnings/masked-exit-status-fails-open.md` — the guard then fails open
instead of inverted, which is worse, not better.

## Sites in this repo that depend on "exactly one match"

All three are correct today and all three are one duplicate match away from
aborting their script under `set -e`:

- `Scripts/build-engine.sh:58` — `cmake --target help | grep -i pk3 | head -1`
- `Scripts/build-engine.sh:70` — `find ... -name 'woof.pk3' | head -1`
- `Scripts/capture-screenshots.sh:64` — `simctl list | grep -F | head -1`

## Why there is no guard script yet

A text scan that flags `| grep -q` and `| head` inside a `pipefail` script
would land red on those three sites, and exempting the exact lines at risk
would make the check theatre. Fix the three first; a guard is worth writing
once its clean state is reachable.

**Provenance:** paid for on 2026-08-17 in the `doom-ios-2026` → `waddle`
migration script, whose precondition check refused to run against a correct
repository and would have proceeded against one missing the rename.
