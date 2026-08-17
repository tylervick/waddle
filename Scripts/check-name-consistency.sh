#!/bin/bash
# Refuses tracked files that spell the app's name "WADdle".
#
# The name is "Waddle". "WADdle" is a WORDMARK -- a visual treatment of that
# name, not a spelling of it. That distinction decays silently, because a
# stylized spelling reads as deliberate wherever it lands, so nobody deletes
# it. The previous rename (BoomBox -> WADdle) left residue that survived for
# weeks, including an App/BoomBox.xcodeproj nobody noticed; this check exists
# so the next rename does not repeat it.
#
# Scans TRACKED files only. Build outputs, vendored archives and generated
# projects are not ours to spell.
#
# Reports EVERY offending file in one run rather than stopping at the first,
# so a fix-up is one round trip.
#
# The exemptions below are RULES, each with a reason. A new entry here is a
# signal that the rule is being eroded -- argue it in review, do not add it
# quietly. See docs/learnings/the-name-is-waddle.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Path prefixes that may carry the wordmark spelling, and why.
EXEMPT=(
    'Design/'                                 # the wordmark itself lives here
    'docs/superpowers/plans/'                 # dated records of completed work
    'docs/superpowers/specs/'                 # dated records of completed work
    'docs/learnings/the-name-is-waddle.md'    # states the rule, must name the spelling
    'Scripts/check-name-consistency.sh'       # this guard
    'Scripts/test-check-name-consistency.sh'  # and its tests
)

# Exact strings that name something OUTSIDE this repo, where the spelling is
# not ours to choose. Allowed in any file, because the alternative -- exempting
# whole files that otherwise need sweeping -- is far broader.
#
# "WADdle App Store CI" is a provisioning profile registered in Apple's
# developer portal and confirmed to still carry that spelling. It appears in
# App/ExportOptions-ci.plist and App/project.yml, and both must match the
# portal exactly: a mismatch fails the archive with an error naming neither
# signing nor the profile. Rename it portal-first, at the next regeneration,
# then drop this entry.
ALLOWED_LITERALS=(
    'WADdle App Store CI'
)

is_exempt() { # path
    local path="$1" prefix
    for prefix in "${EXEMPT[@]}"; do
        case "$path" in "$prefix"*) return 0 ;; esac
    done
    return 1
}

# Fails CLOSED. `git grep` exits 0 with matches, 1 with none, and >1 on a real
# error -- an unreadable tracked file, or no git work tree at all. The obvious
# `git ls-files -z | xargs -0 grep -Il ... || true` shape folds that third case
# into "no matches" and reports a clean tree it never finished reading, which is
# how a guard fails open. This repo has paid for that four times; see
# docs/learnings/masked-exit-status-fails-open.md. Only status 1 means clean.
#
# -z keeps the path list NUL-delimited, so a newline in a filename cannot forge
# an extra entry, and -I skips binaries.
scan="$(mktemp)"
trap 'rm -f "$scan"' EXIT

status=0
git grep -I -l -z -e 'WADdle' -- . > "$scan" || status=$?
if [ "$status" -gt 1 ]; then
    echo "error: the name scan itself failed (git grep exit $status) —" >&2
    echo "       refusing to report a tree it never finished reading." >&2
    exit "$status"
fi

# A file "still offends" only if the spelling survives once every allowed
# external literal is removed from it. sed strips the literals, then the file
# is re-checked; a file that only ever named the profile falls out here.
still_offends() { # path
    local path="$1" lit
    local -a strip=()
    for lit in "${ALLOWED_LITERALS[@]}"; do
        strip+=(-e "s/${lit//\//\\/}//g")
    done
    sed "${strip[@]}" -- "$path" 2>/dev/null | grep -q -- 'WADdle'
}

offenders=()
while IFS= read -r -d '' path; do
    is_exempt "$path" && continue
    still_offends "$path" && offenders+=("$path")
done < "$scan"

if [ "${#offenders[@]}" -gt 0 ]; then
    echo "error: the app's name is \"Waddle\". \"WADdle\" is the wordmark and" >&2
    echo "       belongs only in Design/. These tracked files spell it \"WADdle\":" >&2
    printf '         %s\n' "${offenders[@]}" >&2
    echo "       If one of these genuinely needs the wordmark, say why in review" >&2
    echo "       before adding it to EXEMPT in $0." >&2
    exit 1
fi
