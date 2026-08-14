#!/bin/bash
# Decides whether an agent-loop run happens, and which issue it takes.
#
# The loop agent runs this as its FIRST action and stops if refused. It is not
# wired as Orca's --precheck: a spike found `orca automations run` skips that
# hook entirely (precheckResult stayed null for both exit 0 and exit 1), and the
# rollout deliberately starts with manual runs. Gating from inside the agent
# behaves identically for manual and scheduled fires.
#
# Contract:
#   proceed -> print ONLY the issue number on stdout, exit 0
#   refuse  -> print "skip: <reason>" on stderr, nothing on stdout, exit 1
# Nothing else may reach stdout, because the caller reads it as the selection.
#
# Refusing is the common case and costs nothing. The three refusals, in order:
#
#   1. Stale engine in this checkout. Every worktree clones Vendor/out from
#      here, so a stale root makes check-engine-fresh.sh fail closed inside the
#      run and burns ~25 minutes of a 45-minute budget on a rebuild. The
#      resulting failures would look like agent failures and be nothing of the
#      sort.
#   2. A run is already live. One at a time is what makes it impossible for two
#      xcodebuild sessions to share a simulator.
#   3. Nothing claimable. The backlog is finite by design; exhausting it is the
#      graceful end of the experiment, not an error.
#
# Liveness is the agent:in-progress LABEL, never the presence of a worktree --
# Orca leaves worktrees behind after `automations remove`, so a leftover one
# must not read as a running job.
#
# NOT a pure query: clearing a stale claim mutates labels. That is correct
# however often it happens, but anyone running this by hand should know. Every
# sweep is logged to stderr.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 2h; comfortably past the ~105m worst-case run (45m work budget + 15m
# CI/review wait + up to 3 x 900s fix rounds).
STALE_CLAIM_SECONDS=7200
# 4h; well above that same ~105m ceiling, and deliberately its own constant
# rather than reusing STALE_CLAIM_SECONDS: this sweep can only see a
# worktree's start time, never whether the run inside it is still live, so its
# threshold must clear the worst case with real margin, not merely exceed the
# common case.
STALE_WORKTREE_SECONDS=14400
CLAIM_LABEL="agent:in-progress"

# LOOP_NOW lets the self-test pin "now". Unset in production.
NOW_ISO="${LOOP_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
to_epoch() { date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || echo 0; }
NOW_EPOCH="$(to_epoch "$NOW_ISO")"

skip() { echo "skip: $*" >&2; exit 1; }

# 1. Engine freshness in THIS checkout.
#
# check-engine-fresh.sh already prints the command that clears this. Passing its
# output through rather than composing a second copy here is deliberate: two
# hand-maintained copies of a fix instruction drift, and a message that names a
# stale remedy is worse than one that names none.
#
# Its wording says "before archiving" because archive.sh is its other caller, so
# the loop's own reason is stated separately rather than restating either. That
# reason is the part an operator needs: this is a state the loop CANNOT clear
# itself -- Engine/woof and the engine build are on its never-touch list -- so
# unlike every other skip here, this one is addressed to a human who has to act.
if ! engine_msg="$("$ROOT/Scripts/check-engine-fresh.sh" 2>&1)"; then
    skip "root checkout's engine is stale; every worktree would inherit it and rebuild.
       The loop cannot clear this itself, and will refuse every run until someone
       rebuilds in the ROOT checkout (not in a worktree):

$engine_msg"
fi

# 2. Sweep abandoned per-run worktrees.
#
# `orca automations remove` does not delete the worktrees Orca creates per run,
# and a run cannot delete the one it is executing inside. At three runs a day
# they accumulate indefinitely.
#
# Start of run is the only workable moment. A run that crashes cannot clean up
# after itself by definition, so end-of-run cleanup would only ever fire in the
# case where there is nothing to clean.
#
# This sweep uses its own STALE_WORKTREE_SECONDS threshold, not
# STALE_CLAIM_SECONDS -- and deliberately a much larger one. Unlike the
# stale-claim sweep above, this one can only see a worktree's start-time-encoded
# name; it has no way to ask whether the run inside it is still alive. A
# threshold merely past the work budget would risk `orca worktree rm`-ing a
# live run's own worktree out from under it while section 4 (waiting on CI and
# CodeRabbit, then up to three fix rounds) is still in progress.
#
# Age comes from the timestamp Orca puts in the worktree name
# (auto-waddle-loop-run-<n>-<YYYYMMDDTHHMM>) rather than filesystem mtime, so it
# is deterministic and testable. If that convention ever changes the name will
# stop parsing, and this reports it loudly rather than quietly sweeping nothing.
#
# Removing a swept worktree cannot strand a pull request: the loop pushes its
# branch to origin long before any worktree is old enough to qualify.
#
# The trailing `|| true` is load-bearing, not decoration. `grep` exits 1 when
# nothing matches, and under this script's `set -euo pipefail` that failure
# (or a `while` loop whose body never runs, which itself exits non-zero at
# EOF) would otherwise abort the whole precheck before it ever reaches `gh
# issue list` -- silently, with no `skip:` reason, on the ordinary day when
# there is nothing to sweep. A failed `orca worktree list` collapses to the
# same "no matches" shape and must not abort the run either: the sweep is
# hygiene, and hygiene failing must never stop the run from doing its actual
# job.
if command -v orca >/dev/null 2>&1; then
    orca worktree list 2>/dev/null | awk '{print $3}' | grep '/auto-waddle-loop-' \
    | while read -r wt_path; do
        base="$(basename "$wt_path")"
        stamp="${base##*-}"
        case "$stamp" in
            [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9]) ;;
            *)
                echo "worktree sweep: cannot parse a timestamp from '$base'; skipping it" >&2
                continue ;;
        esac
        d="${stamp%T*}"; t="${stamp#*T}"
        wt_iso="${d:0:4}-${d:4:2}-${d:6:2}T${t:0:2}:${t:2:2}:00Z"
        wt_epoch="$(to_epoch "$wt_iso")"
        # A shape-valid but CALENDAR-INVALID stamp (e.g. Feb 30th) must not be
        # scored as an age. `to_epoch` echoes 0 when `date -j -f` outright
        # rejects its input, but that is not the only failure shape: on this
        # platform's `date`, an out-of-range day within an in-range month
        # (Feb 30, or day 31 of a 30-day month) does not get rejected at all
        # -- `mktime` silently normalizes it ("2026-02-30" becomes
        # "2026-03-02") and returns success. A bare `wt_epoch = 0` check would
        # miss that second shape entirely, and a normalized-but-wrong date can
        # land anywhere -- including, as here, far enough in the past to read
        # as a plausible stale worktree and get swept. Round-tripping the
        # epoch back through the same format catches both shapes uniformly: a
        # genuinely valid stamp always reformats back to itself, so any
        # mismatch -- whether from the 0 fallback or from silent
        # normalization -- means the input was never a real calendar date.
        # Fail closed exactly like the "no labeling event" guard above: a
        # timestamp the code cannot trust is UNKNOWN age, never ancient age,
        # and unknown age must never sweep.
        roundtrip="$(date -u -r "$wt_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
        if [ "$roundtrip" != "$wt_iso" ]; then
            echo "worktree sweep: '$base' decodes to a calendar-invalid date ('$wt_iso'); skipping it" >&2
            continue
        fi
        wt_age=$(( NOW_EPOCH - wt_epoch ))
        if [ "$wt_age" -ge "$STALE_WORKTREE_SECONDS" ]; then
            if orca worktree rm --worktree "path:$wt_path" >/dev/null 2>&1; then
                echo "swept abandoned worktree $base (${wt_age}s old)" >&2
            else
                echo "worktree sweep: could not remove '$base'" >&2
            fi
        fi
    done || true
fi

# 3. Fetch the world in two calls, then decide locally.
issues="$(gh issue list --label agent:eligible --state open --limit 1000 \
            --json number,labels 2>/dev/null)" || skip "gh issue list failed"
open_prs="$(gh pr list --state open --limit 1000 --json number,body 2>/dev/null)" \
    || skip "gh pr list failed"

# 4. Liveness + stale sweep.
claimed="$(printf '%s' "$issues" | python3 -c 'import json,sys
for i in json.load(sys.stdin):
    if any(l["name"]=="agent:in-progress" for l in i["labels"]): print(i["number"])')"

swept=""
for n in $claimed; do
    # --paginate is required: the timeline endpoint pages at 30 events, and an
    # issue that has been claimed/swept/re-claimed repeatedly accumulates more
    # than that, pushing the very labeling event we need off page 1.
    #
    # Absence of a matching event is treated as LIVE, never as stale. An
    # unpaginated call that missed the event on page 2+ used to fall back to
    # the 1970 epoch, which scored a live claim as ~56 years old and swept it
    # -- handing the same issue to a second concurrent run. "I found no event"
    # is not evidence of age; it is evidence of nothing, and the fail-closed
    # reading of nothing is to refuse, not to sweep.
    applied="$(gh api --paginate "repos/{owner}/{repo}/issues/$n/timeline" 2>/dev/null \
                 | python3 -c 'import json, sys
# --paginate prints one JSON array per page, concatenated back to back with no
# separator or wrapping -- NOT a single JSON document -- so a plain
# json.load() would raise on any issue with more than one page. Decode
# documents off the stream one at a time instead; this also still handles the
# single-page case the hermetic tests fixture.
decoder = json.JSONDecoder()
data = sys.stdin.read().strip()
events = []
idx = 0
while idx < len(data):
    obj, end = decoder.raw_decode(data, idx)
    events.extend(obj)
    idx = end
    while idx < len(data) and data[idx] in " \t\r\n":
        idx += 1
hits = [e["created_at"] for e in events
        if e.get("event") == "labeled"
        and (e.get("label") or {}).get("name") == "agent:in-progress"]
print(hits[-1] if hits else "")')" || skip "gh api timeline failed for #$n"
    if [ -z "$applied" ]; then
        skip "run already live on #$n (no agent:in-progress labeling event found anywhere in its timeline; cannot prove the claim is stale)"
    fi
    age=$(( NOW_EPOCH - $(to_epoch "$applied") ))
    if [ "$age" -lt "$STALE_CLAIM_SECONDS" ]; then
        skip "run already live on #$n (claimed ${age}s ago)"
    fi
    gh issue edit "$n" --remove-label "$CLAIM_LABEL" >/dev/null 2>&1 \
        || skip "could not clear the stale claim on #$n"
    echo "swept stale claim on #$n (${age}s old)" >&2
    swept="$swept $n"
done

# 5. Select. SWEPT carries the numbers just cleared above -- `issues` is a
# snapshot fetched before the sweep, so without this an issue swept this run
# would still show its now-removed agent:in-progress label and get excluded
# by the very filter meant to let it back in.
choice="$(printf '%s\n%s' "$issues" "$open_prs" | SWEPT="$swept" python3 -c '
import json, os, re, sys
raw = sys.stdin.read()
issues_txt, prs_txt = raw.split("\n[", 1) if raw.count("\n[") else (raw, "[]")
issues = json.loads(issues_txt)
prs = json.loads("[" + prs_txt)
swept = {int(n) for n in os.environ.get("SWEPT", "").split()}
linked = set()
for p in prs:
    # GitHub honours NINE closing keywords, not three. `Fixed #41` closes an
    # issue exactly as hard as `Closes #41`, and `GH-41` is an accepted
    # reference form. Matching only closes/fixes/resolves left an issue with an
    # open pull request looking unclaimed, so the loop could pick it up and do
    # the work a second time.
    linked.update(int(m) for m in re.findall(
        r"(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+(?:#|GH-)(\d+)",
        p.get("body") or "", re.I))
rank = {"size:xs": 0, "size:s": 1, "size:m": 2}
best = None
for i in issues:
    names = {l["name"] for l in i["labels"]}
    if "agent:stuck" in names:
        continue
    if "agent:in-progress" in names and i["number"] not in swept:
        continue
    if i["number"] in linked:
        continue
    r = min((rank[n] for n in names if n in rank), default=3)
    # agent:next outranks size entirely. Size ordering is a throughput
    # heuristic -- finish the cheap things first -- and it has no way to say
    # "this specific one matters now". Without an override the only ways to
    # steer are relabelling the size, which lies about the work and corrupts
    # the `size` field trial records carry as experiment data, or making every
    # competing issue ineligible, which was 17 label edits when this was added.
    key = (0 if "agent:next" in names else 1, r, i["number"])
    if best is None or key < best[0]:
        best = (key, i["number"])
print(best[1] if best else "")
')"

[ -n "$choice" ] || skip "no claimable agent:eligible issue"
echo "$choice"
