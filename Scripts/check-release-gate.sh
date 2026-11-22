#!/bin/bash
# Refuses a ci.yml whose `testflight` job could ship a build that some check
# in the same workflow has not passed.
#
# The release job runs after the tests only because its `needs:` says so.
# While the tests were one job ("Build + unit tests") that was one name and
# hard to get wrong. Since they were split into parallel jobs (the helper
# suites, and one unit-test leg per simulator, PR #448) the gate is a LIST,
# and each of these is a quiet way to open it:
#
#   1. A job is added to ci.yml and not to `testflight`'s `needs:`. It runs,
#      it can go red, and the release does not wait for it.
#   2. `testflight`'s `if:` gains a status function -- always(), cancelled(),
#      failure(), or the common `!cancelled()`. An `if:` with none of them
#      keeps an implicit success(), which is what makes a failed OR cancelled
#      leg (issue #415: jobs cancelled from outside, mid-test) skip the
#      release. With one, a release can follow a red or cancelled leg.
#   3. A job the release needs is marked `continue-on-error: true`, so its
#      failure counts as success to everything downstream.
#   4. `testflight`'s `if:` stops saying "a push to main": it is deleted, or
#      loosened with an `||`. The `app-store` environment admits `main` only,
#      so this would not ship a branch; it would run release jobs, and fail
#      them, on every pull request. Still not what the gate says it is.
#   5. A job the release needs has an `if:` of its own. A needed job that is
#      skipped skips the release with it, so a check that only runs on pull
#      requests, added to the list as rule 1 asks, would stop every release
#      without anything going red.
#
# What it does NOT see, so that an "ok" is not read for more than it is: a
# step-level `continue-on-error` inside a needed job, a leg taken out of the
# unit-test matrix, and anything in testflight.yml.
#
# So: every job in ci.yml must either be named in `testflight`'s `needs:` or
# be on the list below of jobs that publish something instead of checking
# something. A new job fails this guard until someone decides which it is.
#
# There is no skip path. The input is one tracked file; a file that is
# missing, or has no `testflight` job, is a failure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Overridable so the test suite can point the guard at a fixture.
CI_FILE="${RELEASE_GATE_CI_FILE:-$ROOT/.github/workflows/ci.yml}"
GATED_JOB=testflight

# Jobs that are not checks, and so are not waited for. `changed-paths` and
# `revyl-preview` publish a preview for a pull request and never run on
# `main`; `revyl-main` publishes main's build and is itself behind the tests.
NOT_A_CHECK=" changed-paths revyl-preview revyl-main "

violations=0
err() {
    echo "error: $1" >&2
    violations=$((violations + 1))
}

if [ ! -r "$CI_FILE" ]; then
    echo "error: $CI_FILE is not readable" >&2
    exit 1
fi

# One record per fact, tab-separated:
#   job <id>
#   needs <id> <needed id>
#   if <id> <the whole expression on one line>
#   coe <id>              (the job has `continue-on-error:` other than false)
#   unread <line>         (a key under `jobs:` this could not read as a job id)
# Job ids are the two-space-indented keys under `jobs:`, bare or quoted, with
# or without a trailing comment (`  lint: # new` and `  "lint":` are jobs to
# GitHub, and were not to the first version of this pattern, which let a new
# job through unseen); a job's own keys are four-space-indented, which is what keeps a step's `if:` or
# `continue-on-error:` (eight spaces or more) out of this. `needs:` is read in
# all three spellings: a scalar, a flow list `[a, b]`, and a block list. An
# `if:` may be folded over several lines; everything indented deeper than its
# key belongs to it.
facts() {
    awk '
        function emit_needs(s,   n, parts, i) {
            gsub(/[][,"\047]/, " ", s)
            n = split(s, parts, /[[:space:]]+/)
            for (i = 1; i <= n; i++)
                if (parts[i] != "") printf "needs\t%s\t%s\n", job, parts[i]
        }
        function flush_if() {
            if (in_if) { printf "if\t%s\t%s\n", job, iftext; in_if = 0; iftext = "" }
        }
        /^jobs:[[:space:]]*$/ { injobs = 1; next }
        /^[^[:space:]#]/ { flush_if(); injobs = 0; job = ""; next }
        !injobs { next }
        /^[[:space:]]*#/ { next }
        /^  ["\047]?[A-Za-z0-9_.-]+["\047]?:[[:space:]]*(#.*)?$/ {
            flush_if(); in_needs = 0
            job = $1; sub(/:.*$/, "", job); gsub(/["\047]/, "", job)
            printf "job\t%s\n", job; next
        }
        # Any other two-space key is a job this pattern cannot name. Say so
        # instead of reading its keys as belonging to the job before it.
        /^  [^[:space:]#-]/ {
            flush_if(); in_needs = 0; job = ""
            printf "unread\t%s\n", $0; next
        }
        job == "" { next }
        /^    [A-Za-z0-9_-]+:/ {
            flush_if(); in_needs = 0
            key = $1; sub(/:.*$/, "", key)
            rest = $0; sub(/^    [A-Za-z0-9_-]+:[[:space:]]*/, "", rest)
            sub(/[[:space:]]+#.*$/, "", rest)
            if (key == "needs") { if (rest == "") in_needs = 1; else emit_needs(rest) }
            else if (key == "if") { in_if = 1; iftext = rest }
            else if (key == "continue-on-error" && rest != "false") printf "coe\t%s\n", job
            next
        }
        in_needs && /^      - / { s = $0; sub(/^      - /, "", s); sub(/[[:space:]]+#.*$/, "", s); emit_needs(s); next }
        in_if { s = $0; sub(/^[[:space:]]+/, "", s); iftext = iftext " " s; next }
        END { flush_if() }
    ' "$CI_FILE"
}

FACTS="$(facts)"

# Lines of field 2 (and 3) for one record kind, optionally for one job.
jobs_list()  { printf '%s\n' "$FACTS" | awk -F'\t' '$1 == "job" { print $2 }'; }
needs_of()   { printf '%s\n' "$FACTS" | awk -F'\t' -v j="$1" '$1 == "needs" && $2 == j { print $3 }'; }
if_of()      { printf '%s\n' "$FACTS" | awk -F'\t' -v j="$1" '$1 == "if" && $2 == j { print $3 }'; }
has_coe()    { printf '%s\n' "$FACTS" | awk -F'\t' -v j="$1" '$1 == "coe" && $2 == j { found = 1 } END { exit !found }'; }
is_job()     { printf '%s\n' "$FACTS" | awk -F'\t' -v j="$1" '$1 == "job" && $2 == j { found = 1 } END { exit !found }'; }

if ! is_job "$GATED_JOB"; then
    echo "error: $CI_FILE has no '$GATED_JOB' job, so there is no release gate to check (was it renamed? this guard names it in GATED_JOB)" >&2
    exit 1
fi

# A line under `jobs:` at a job's depth that is not a job id this can read.
# Refused, not skipped: a job the guard cannot see is a job nobody is made to
# decide about.
while IFS= read -r line; do
    [ -n "$line" ] || continue
    err "ci.yml has a line at job depth that is not a job id this guard can read: '$line'"
done < <(printf '%s\n' "$FACTS" | awk -F'\t' '$1 == "unread" { print $2 }')

NEEDED=" $(needs_of "$GATED_JOB" | tr '\n' ' ')"

# 1. Every job is waited for, or is on the list of jobs that are not checks.
checks=0
while IFS= read -r job; do
    [ -n "$job" ] || continue
    [ "$job" = "$GATED_JOB" ] && continue
    case "$NOT_A_CHECK" in *" $job "*) continue ;; esac
    checks=$((checks + 1))
    case "$NEEDED" in
        *" $job "*) ;;
        *) err "ci.yml job '$job' is not in the '$GATED_JOB' job's needs:, so a release would not wait for it. If it is a check that runs on every push to main, add it to that list (a job with an if: of its own cannot go there: skipped, it would skip the release). If it publishes rather than checks, or runs only on pull requests, add it to NOT_A_CHECK in $(basename "$0")" ;;
    esac
done < <(jobs_list)

if [ "$checks" -eq 0 ]; then
    err "ci.yml has no job for '$GATED_JOB' to wait for: every job is either '$GATED_JOB' or on the NOT_A_CHECK list"
fi

# A needed name that is no job is a typo GitHub rejects the whole workflow
# for; say which name, since its message would not reach a pull request's
# checks at all.
for needed in $NEEDED; do
    if ! is_job "$needed"; then
        err "'$GATED_JOB' needs '$needed', which is not a job in ci.yml"
    fi
    # 3. A needed job must not turn its own failure into a success.
    if has_coe "$needed"; then
        err "ci.yml job '$needed' sets continue-on-error, so its failure would count as a success to '$GATED_JOB'"
    fi
    # 5. Nor may it be skippable: a skipped need skips the release.
    needed_if="$(if_of "$needed")"
    if [ -n "$needed_if" ]; then
        err "ci.yml job '$needed' has an if: of its own ($needed_if), and '$GATED_JOB' needs it: whenever it is skipped, the release is skipped too, and nothing goes red"
    fi
done

# 2. The implicit success() must still be there.
# -i: GitHub's expression functions are case-insensitive, so `Always()` and
# `!Cancelled()` remove the implicit success() exactly as the lowercase
# spellings do.
condition="$(if_of "$GATED_JOB")"
if printf '%s' "$condition" | grep -Eiq '(always|cancelled|failure|success)[[:space:]]*\('; then
    err "the '$GATED_JOB' job's if: calls a status function ($condition). Without one it keeps an implicit success(), which is what skips a release when a needed job failed or was cancelled; remove the call"
fi

# 4. It must still be "a push, to main", and nothing may widen it. Compared
#    with the spaces taken out, so the spelling of the two tests is pinned and
#    their spacing is not.
squeezed="$(printf '%s' "$condition" | tr -d '[:space:]')"
for want in "github.event_name=='push'" "github.ref=='refs/heads/main'"; do
    case "$squeezed" in
        *"$want"*) ;;
        *) err "the '$GATED_JOB' job's if: (${condition:-none}) does not test $want, so the release is no longer limited to a push to main" ;;
    esac
done
case "$squeezed" in
    *'||'*) err "the '$GATED_JOB' job's if: ($condition) contains ||, which can let the release run on something other than a push to main; keep it a plain && of the two tests" ;;
esac
case "$squeezed" in
    *'!='*|*'!('*|*'!github'*) err "the '$GATED_JOB' job's if: ($condition) negates something; keep it a plain && of the two tests" ;;
esac

if [ "$violations" -ne 0 ]; then
    echo "check-release-gate: $violations problem(s)" >&2
    exit 1
fi

echo "check-release-gate: ok - '$GATED_JOB' waits for all $checks check job(s):$(printf '%s' "$NEEDED" | sed 's/ $//')"
