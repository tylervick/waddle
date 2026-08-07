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
STALE_CLAIM_SECONDS=7200   # 2h; comfortably past the 45m wall-clock budget
CLAIM_LABEL="agent:in-progress"

# LOOP_NOW lets the self-test pin "now". Unset in production.
NOW_ISO="${LOOP_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
to_epoch() { date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || echo 0; }
NOW_EPOCH="$(to_epoch "$NOW_ISO")"

skip() { echo "skip: $*" >&2; exit 1; }

# 1. Engine freshness in THIS checkout.
if ! "$ROOT/Scripts/check-engine-fresh.sh" >/dev/null 2>&1; then
    skip "root checkout's engine is stale; every worktree would inherit it and rebuild"
fi

# 2. Fetch the world in two calls, then decide locally.
issues="$(gh issue list --label agent:eligible --state open --limit 1000 \
            --json number,labels 2>/dev/null)" || skip "gh issue list failed"
open_prs="$(gh pr list --state open --limit 1000 --json number,body 2>/dev/null)" \
    || skip "gh pr list failed"

# 3. Liveness + stale sweep.
claimed="$(printf '%s' "$issues" | python3 -c 'import json,sys
for i in json.load(sys.stdin):
    if any(l["name"]=="agent:in-progress" for l in i["labels"]): print(i["number"])')"

swept=""
for n in $claimed; do
    applied="$(gh api "repos/{owner}/{repo}/issues/$n/timeline" 2>/dev/null \
                 | python3 -c 'import json,sys
events = json.load(sys.stdin)
hits = [e["created_at"] for e in events
        if e.get("event") == "labeled"
        and (e.get("label") or {}).get("name") == "agent:in-progress"]
print(hits[-1] if hits else "")')" || skip "gh api timeline failed for #$n"
    age=$(( NOW_EPOCH - $(to_epoch "${applied:-1970-01-01T00:00:00Z}") ))
    if [ "$age" -lt "$STALE_CLAIM_SECONDS" ]; then
        skip "run already live on #$n (claimed ${age}s ago)"
    fi
    gh issue edit "$n" --remove-label "$CLAIM_LABEL" >/dev/null 2>&1 \
        || skip "could not clear the stale claim on #$n"
    echo "swept stale claim on #$n (${age}s old)" >&2
    swept="$swept $n"
done

# 4. Select. SWEPT carries the numbers just cleared above -- `issues` is a
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
    linked.update(int(m) for m in re.findall(r"(?:closes|fixes|resolves)\s+#(\d+)",
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
    key = (r, i["number"])
    if best is None or key < best[0]:
        best = (key, i["number"])
print(best[1] if best else "")
')"

[ -n "$choice" ] || skip "no claimable agent:eligible issue"
echo "$choice"
