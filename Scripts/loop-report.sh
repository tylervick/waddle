#!/bin/bash
# Aggregates agent-loop trial records into the report the experiment exists to
# produce: does the loop help, and did a given prompt edit make it better?
#
# Segmenting by prompt_sha is the point. One overall rate cannot distinguish
# "the loop works" from "the loop broke three prompt edits ago", and the prompt
# is the only variable deliberately changed.
#
# What this script actually computes, exactly:
#   - total trial count and an outcome breakdown
#   - per prompt_sha: trial count, PRs merged without requiring changes, and
#     CodeRabbit Major/Critical findings across those PRs
#   - the lost-trial list (records still reading `started`)
#   - the stuck pile (records with outcome `stuck`)
#
# Two signals feed the per-prompt_sha line above:
#   leading  -- CodeRabbit Major/Critical findings. Fast, graded, what the
#               prompt is tuned against. The agent now fixes findings before a
#               run ends, so this is read from the record's
#               coderabbit_findings_first snapshot, not queried live -- a live
#               query at report time would return post-fix counts. Records
#               written before that field existed fall back to a live query
#               (and the report says so), which understates them.
#   lagging  -- the PR merged without requiring changes. Slow and authoritative;
#               it exists to check the leading signal is telling the truth.
#
# Every trial record also carries `verification_result`, `size`, `kind`, and
# `wall_clock_seconds` (Scripts/loop-prompt.md section 5). This script does not
# read or surface any of those today -- they are captured for later analysis,
# not because a report is already computed from them.
#
# A record whose outcome is still `started` is a LOST TRIAL -- the run died
# before rewriting it. There is no supervising process to notice that (Orca's
# --timeout-ms does not fire), so this report is the only thing that will.
# Malformed records are reported, never skipped: dropping one biases every
# number here invisibly.
set -euo pipefail
TRIALS_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/docs/loop-trials}"
MARKERS='🟠 Major|🔴 Critical'

shopt -s nullglob
files=("$TRIALS_DIR"/*-issue-*.md)
if [ ${#files[@]} -eq 0 ]; then
    echo "no trials recorded in $TRIALS_DIR"
    exit 0
fi

frontmatter() { awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1' "$1"; }
field() { printf '%s\n' "$1" | awk -F': *' -v k="$2" '$1==k{print $2; exit}'; }

total=0; declare -a rows=(); declare -a bad=(); declare -a stuck=(); declare -a lost=()
for f in "${files[@]}"; do
    fm="$(frontmatter "$f")"
    issue="$(field "$fm" issue)"; outcome="$(field "$fm" outcome)"
    if [ -z "$issue" ] || [ -z "$outcome" ]; then bad+=("$(basename "$f")"); continue; fi
    total=$((total + 1))
    rows+=("$(field "$fm" prompt_sha)|$outcome|$(field "$fm" pr)|$issue|$(field "$fm" coderabbit_findings_first)")
    [ "$outcome" = "stuck" ] && stuck+=("$issue")
    [ "$outcome" = "started" ] && lost+=("$issue")
done

echo "trials: $total"
echo
echo "outcomes:"
# ${rows[@]} on a truly empty array (every record malformed, none valid) is an
# unbound-variable error under `set -u` on macOS's bash 3.2 -- bash fixed this
# in 4.4, but the system bash this runs under predates that fix. Guard the
# expansion rather than relying on a bash version this script does not
# control; the header promises malformed records are "reported, never
# skipped", and a crash before reaching that warning breaks the promise.
if [ "${#rows[@]}" -gt 0 ]; then
    printf '%s\n' "${rows[@]}" | cut -d'|' -f2 | sort | uniq -c | sed 's/^/  /'
fi
echo

echo "by prompt version:"
if [ "${#rows[@]}" -gt 0 ]; then
    for sha in $(printf '%s\n' "${rows[@]}" | cut -d'|' -f1 | sort -u); do
        n=0; merged=0; prs=0; findings=0; legacy=0
        for r in "${rows[@]}"; do
            [ "${r%%|*}" = "$sha" ] || continue
            n=$((n + 1))
            pr="$(printf '%s' "$r" | cut -d'|' -f3)"
            # A trial with no PR feeds neither signal. Counting it as zero findings
            # would score a dead run as a flawless review.
            [ "$pr" = "none" ] && continue
            prs=$((prs + 1))
            state="$(gh pr view "$pr" --json state,reviewDecision 2>/dev/null || echo '{}')"
            case "$state" in
                *'"MERGED"'*) case "$state" in
                    *CHANGES_REQUESTED*) ;;
                    *) merged=$((merged + 1)) ;;
                esac ;;
            esac
            crf="$(printf '%s' "$r" | cut -d'|' -f5)"
            if [ -n "$crf" ] && [ "$crf" != "none" ]; then
                findings=$((findings + crf))
            else
                # Pre-snapshot record. Query live, but say so: since the agent now
                # fixes findings before a run ends, this number is post-fix and
                # understates what the run originally produced.
                legacy=$((legacy + 1))
                c="$(gh api "repos/{owner}/{repo}/pulls/$pr/comments" --jq '.[].body' 2>/dev/null \
                      | grep -c -E "$MARKERS" || true)"
                findings=$((findings + c))
            fi
        done
        if [ "$prs" -gt 0 ]; then
            echo "  $sha: $n trials, $merged merged without changes, $findings CodeRabbit Major/Critical across $prs PR(s)"
        else
            echo "  $sha: $n trials, no PRs opened"
        fi
        if [ "$legacy" -gt 0 ]; then
            echo "    ($legacy legacy record(s) predate coderabbit_findings_first; scored by live query, which is post-fix and may understate)"
        fi
    done
fi
echo

if [ ${#lost[@]} -gt 0 ]; then
    echo "LOST TRIALS (run died before recording an outcome): ${lost[*]}"
    echo "  These are runs that started and never finished. Nothing else detects them."
    echo
fi
if [ ${#stuck[@]} -gt 0 ]; then
    echo "stuck pile (needs human triage): ${stuck[*]}"
    echo
fi
if [ ${#bad[@]} -gt 0 ]; then
    echo "WARNING: ${#bad[@]} unparseable record(s), excluded from every number above:" >&2
    printf '  malformed: %s\n' "${bad[@]}" >&2
fi
