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
#               written before that field existed entirely fall back to a
#               live query (and the report says so, as its own "legacy"
#               line), which understates them. A record that HAS the field
#               but reads the literal `none` (a 900s wait that expired with no
#               review landing), the literal `unavailable` (CodeRabbit
#               reporting outright that it would not review), or something
#               malformed is a different situation: there is no pre-fix number
#               *in the record*. Normally that also means never queried live --
#               conflating it with the legacy case would fabricate a post-fix
#               number for a trial that measured nothing -- so it is excluded
#               from the findings total and reported on its own "unavailable"
#               line instead.
#
#               One narrow exception recovers a real measurement instead of
#               discarding it: RECONCILIATION. `none` and `unavailable` are
#               equally unmeasured at run time -- a 900s timeout and an
#               explicit refusal both mean "no review happened yet", not
#               "reviewed and found nothing" -- so both are eligible. If, in
#               addition, the record's `fix_rounds` is `0` (the run never
#               touched the code after opening its PR) AND every commit on
#               that PR is authored by the agent identity
#               (agent-loop@tylervick.com, checked live via `gh api
#               .../pulls/<PR>/commits`), then a CodeRabbit review landing
#               after the run ended is reviewing exactly the code the run
#               produced -- a live query today recovers the same pre-fix count
#               a snapshot would have captured, had one been possible. The
#               authorship check exists because `fix_rounds: 0` alone only
#               proves the *loop* never pushed again -- it says nothing about
#               whether a human did. A human commit on the PR after the loop
#               stopped means a later review is reviewing the human's code,
#               and reconciling would credit the loop with someone else's
#               work. This is not a theoretical risk: PR #61's run recorded
#               `unavailable` with `fix_rounds: 0`, but a human pushed a
#               follow-up commit before CodeRabbit reviewed, so that trial
#               must be refused despite otherwise qualifying. Reconciled
#               records are counted in the findings total and reported on
#               their own "reconciled" line, distinct from both "legacy" (the
#               field predates the schema) and "unavailable" (no measurement
#               exists, live or otherwise) -- the provenance genuinely
#               differs from both. A record that qualifies on every count but
#               the authorship check says so explicitly in the output, since
#               "refused for a foreign commit" is a meaningfully different
#               outcome than "never eligible to begin with".
#   lagging  -- the PR merged without requiring changes. Slow and authoritative;
#               it exists to check the leading signal is telling the truth.
#
# Every trial record also carries `verification_result`, `size`, `kind`,
# `wall_clock_seconds`, `ci_result`, and `coderabbit_findings_after`
# (Scripts/loop-prompt.md section 6). This script does not read or surface any
# of those today -- they are captured for later analysis, not because a report
# is already computed from them. `coderabbit_findings_after` in particular is
# written by the protocol and read by nothing. `fix_rounds` is the one field
# from that list this script does read, solely to decide reconciliation
# eligibility above.
#
# A record whose outcome is still `started` is a LOST TRIAL -- the run died
# before rewriting it. There is no supervising process to notice that (Orca's
# --timeout-ms does not fire), so this report is the only thing that will.
# Malformed records are reported, never skipped: dropping one biases every
# number here invisibly.
set -euo pipefail
TRIALS_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/docs/loop-trials}"
MARKERS='🟠 Major|🔴 Critical'
AGENT_EMAIL='agent-loop@tylervick.com'

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
    rows+=("$(field "$fm" prompt_sha)|$outcome|$(field "$fm" pr)|$issue|$(field "$fm" coderabbit_findings_first)|$(field "$fm" fix_rounds)")
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
        n=0; merged=0; prs=0; findings=0; legacy=0; unavailable=0; reconciled=0; foreign=0
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
            case "$crf" in
                '')
                    # The field is ABSENT ENTIRELY -- a record written before
                    # coderabbit_findings_first existed. This is the only
                    # situation where a live query is legitimate: the run
                    # predates the field, so there is no snapshot to fall back
                    # on except GitHub's current state. It is still post-fix
                    # and may understate, which is why it is reported
                    # separately below rather than folded in silently. Filter
                    # to the trusted-app allowlist (Scripts/loop-prompt.md,
                    # section 4's intro) -- this is a public repo, and an
                    # unfiltered query would count any author's comment text,
                    # including a human contributor's or the owner's own.
                    legacy=$((legacy + 1))
                    c="$(gh api "repos/{owner}/{repo}/pulls/$pr/comments" --paginate \
                          --jq '.[] | select(.user.login as $l | ["coderabbitai[bot]","renovate[bot]"] | index($l)) | .body' 2>/dev/null \
                          | grep -c -E "$MARKERS" || true)"
                    findings=$((findings + c))
                    ;;
                none|unavailable|*[!0-9]*)
                    # The field is PRESENT but unusable: the literal `none`
                    # (a 900s wait that expired with no review landing), the
                    # literal `unavailable` (CodeRabbit reporting outright
                    # that it would not review, e.g. rate limiting), or a
                    # non-numeric/decorated value (e.g. "none (CI timed out)",
                    # "n/a") -- the protocol only ever promises an integer or
                    # one of those two literals, and nothing validates that an
                    # agent actually wrote one. `unavailable` would in fact
                    # already fall into the `*[!0-9]*` glob below (it is
                    # non-empty and every character is a non-digit), but it is
                    # listed explicitly so this branch documents the literal
                    # the protocol actually writes rather than relying on it
                    # merely surviving the wildcard by coincidence. $((...))
                    # evaluates the field's contents as arithmetic, so
                    # treating any of these as a number here would abort the
                    # whole report under `set -euo pipefail` -- silencing the
                    # LOST TRIALS section for every record, not just this one.
                    #
                    # By default none of these may be queried live: unlike the
                    # absent-field case above, a snapshot field exists here
                    # and it says nothing was measured, so a live query would
                    # not recover a pre-fix number -- it would fabricate one,
                    # scoring a trial that measured nothing as though it had a
                    # real result.
                    #
                    # RECONCILIATION is the one exception, and it is narrow on
                    # purpose. `none` and `unavailable` both mean "no
                    # measurement happened", not "measured and found nothing",
                    # so both are equally eligible -- there is no reason to
                    # treat a timeout differently from an explicit refusal.
                    # What makes reconciliation safe is proving the code a
                    # later review would see is the SAME code the run
                    # produced: `fix_rounds: 0` proves the loop itself never
                    # pushed again after opening the PR, but it says nothing
                    # about a human pushing to the same PR afterward -- a
                    # later review would then be reviewing the human's
                    # change, and crediting the loop with it would corrupt
                    # the signal in the other direction from fabrication. So
                    # reconciliation additionally requires every commit on
                    # the PR to be authored by the agent identity. Only when
                    # both hold is a live query today equivalent to the
                    # snapshot that could not be taken at run time.
                    fr="$(printf '%s' "$r" | cut -d'|' -f6)"
                    is_reconciled=0
                    if [ "$fr" = "0" ]; then
                        # `--paginate` in case a PR somehow exceeds one page
                        # of commits; `2>/dev/null || true` so a transient API
                        # failure degrades to "can't confirm" (falls through
                        # to the ordinary unavailable path) rather than
                        # aborting the whole report under `set -euo pipefail`.
                        commit_emails="$(gh api "repos/{owner}/{repo}/pulls/$pr/commits" --paginate \
                              --jq '.[].commit.author.email' 2>/dev/null || true)"
                        if [ -n "$commit_emails" ]; then
                            all_agent=1
                            while IFS= read -r email; do
                                [ -z "$email" ] && continue
                                [ "$email" = "$AGENT_EMAIL" ] || all_agent=0
                            done < <(printf '%s\n' "$commit_emails")
                            if [ "$all_agent" -eq 1 ]; then
                                is_reconciled=1
                            else
                                # Eligible on every other count but refused
                                # for this one: a distinct outcome from never
                                # having been eligible, and worth saying so in
                                # the report rather than folding silently into
                                # the plain unavailable count. This is PR
                                # #61's exact shape: fix_rounds 0, but a
                                # second commit landed from a human author.
                                foreign=$((foreign + 1))
                            fi
                        fi
                    fi
                    if [ "$is_reconciled" -eq 1 ]; then
                        reconciled=$((reconciled + 1))
                        c="$(gh api "repos/{owner}/{repo}/pulls/$pr/comments" --paginate \
                              --jq '.[] | select(.user.login as $l | ["coderabbitai[bot]","renovate[bot]"] | index($l)) | .body' 2>/dev/null \
                              | grep -c -E "$MARKERS" || true)"
                        findings=$((findings + c))
                    else
                        # Excluded from the findings total; count and report
                        # separately so this is never mistaken for the legacy
                        # (field-absent) case or the reconciled case.
                        unavailable=$((unavailable + 1))
                    fi
                    ;;
                *)
                    # Force base 10: a zero-padded value like "08" would otherwise
                    # be read as octal (and "08"/"09" would abort as invalid).
                    findings=$((findings + 10#$crf))
                    ;;
            esac
        done
        if [ "$prs" -gt 0 ]; then
            echo "  $sha: $n trials, $merged merged without changes, $findings CodeRabbit Major/Critical across $prs PR(s)"
        else
            echo "  $sha: $n trials, no PRs opened"
        fi
        if [ "$legacy" -gt 0 ]; then
            echo "    ($legacy legacy record(s) predate coderabbit_findings_first entirely; scored by live query, which is post-fix and may understate)"
        fi
        if [ "$unavailable" -gt 0 ]; then
            echo "    ($unavailable record(s) have an unavailable coderabbit_findings_first -- a 900s wait that expired with no review ('none'), an explicit refusal to review ('unavailable'), or a malformed value -- excluded from the findings total above, never queried live)"
            if [ "$foreign" -gt 0 ]; then
                echo "      ($foreign of the above were otherwise eligible for reconciliation (unusable snapshot, fix_rounds 0, PR exists) but refused: a commit on the PR was not authored by the agent identity, so the PR no longer represents only the loop's own work)"
            fi
        fi
        if [ "$reconciled" -gt 0 ]; then
            echo "    ($reconciled record(s) reconciled -- no measurement existed at run time (fix_rounds 0, so the code was never touched again), and every commit on the PR is authored by the agent, so a live query today reads the same pre-fix code and is counted in the findings total above)"
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
