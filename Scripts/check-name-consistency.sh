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
    # A provisioning-profile name registered in Apple's developer portal, not
    # product text. Renaming it here without renaming it there breaks CI
    # signing with an opaque error; rename it portal-first, at the next
    # profile regeneration.
    'App/ExportOptions-ci.plist'
)

is_exempt() { # path
    local path="$1" prefix
    for prefix in "${EXEMPT[@]}"; do
        case "$path" in "$prefix"*) return 0 ;; esac
    done
    return 1
}

offenders=()
while IFS= read -r path; do
    [ -n "$path" ] || continue
    is_exempt "$path" || offenders+=("$path")
done < <(git ls-files -z | xargs -0 grep -Il -- 'WADdle' 2>/dev/null || true)

if [ "${#offenders[@]}" -gt 0 ]; then
    echo "error: the app's name is \"Waddle\". \"WADdle\" is the wordmark and" >&2
    echo "       belongs only in Design/. These tracked files spell it \"WADdle\":" >&2
    printf '         %s\n' "${offenders[@]}" >&2
    echo "       If one of these genuinely needs the wordmark, say why in review" >&2
    echo "       before adding it to EXEMPT in $0." >&2
    exit 1
fi
