#!/bin/bash
# Refuses a `gh api` call whose exit status is thrown away.
#
# `gh api ... || true` and `gh api ... || echo <fallback>` stop `set -e`
# aborting, and in exchange they destroy the only evidence the call failed.
# The output is then read as an answer -- usually the permissive one. This has
# bitten Scripts/loop-report.sh twice in the same shape:
#
#   - PR #66, reconciliation: a failed comments query produced a count of 0,
#     recorded as a real measurement of "CodeRabbit found nothing".
#   - Issue #68, the legacy live query: the identical bug, left in place when
#     PR #66 fixed its sibling, and reported as a scored legacy record for
#     months. Nobody was looking at it, because it was written down as
#     "tracked separately" rather than checked.
#
# The conforming shape tests the status directly. `set -e` is suspended inside
# an `if` condition and the status of an assignment is the status of its
# command substitution, so this needs no `|| true`:
#
#     if out="$(gh api ... 2>/dev/null)"; then
#         # succeeded -- now interpret $out, including the empty case
#     else
#         # failed -- do not interpret $out at all
#     fi
#
# `|| skip`, `|| err`, and friends are NOT masking: they handle the failure by
# aborting with a reason, which is the whole point. Only `|| true` (discard)
# and `|| echo` (fabricate) are refused.
#
# WHY THIS CHECK COULD NOT BE WRITTEN UNTIL NOW, and what makes it precise:
# `grep -c` exits 1 when nothing matches, which is the expected answer and
# carries no failure information, so `|| true` on a `grep -c` pipeline is
# correct and common in this repo. A naive lint fires on both. The
# discriminator is whether `gh api` is in the same pipeline -- and that only
# became a clean rule once issue #68 removed the last call site where a real
# `gh api` sat in a `grep -c ... || true` pipeline. Every legitimate site
# reads a shell variable (`printf '%s' "$bodies" | grep -c ...`), never gh.
#
# SCOPE, stated plainly so a reader knows what this does not cover:
#   - `gh api` only, which is what docs/learnings/masked-exit-status-fails-open.md
#     describes. `gh pr view ... || echo '{}'` in loop-report.sh is deliberate
#     and fails closed (an unknown state simply never counts as merged), so
#     widening this to every `gh` subcommand would flag correct code.
#   - Lines are joined on a trailing `\`, `|`, `||`, or `&&`. A command
#     substitution spanning lines with no such marker is not joined, so a
#     masked call split that way would be missed. No call site is written that
#     way today; the tests pin both joining forms that exist.
#   - Full-line comments are skipped, so the fixed call sites can keep quoting
#     the bad shape in the comments that explain it.
#   - test-*.sh is skipped: a suite's fixtures contain the bad shape on
#     purpose, including this check's own tests.
#
# Exits 0 and prints nothing when clean; exits 1 naming file and line
# otherwise. Takes a directory to scan, defaulting to this repo's Scripts/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:-$ROOT/Scripts}"

if [ ! -d "$DIR" ]; then
    echo "error: $DIR is not a directory" >&2
    exit 1
fi

status=0
for f in "$DIR"/*.sh; do
    [ -e "$f" ] || continue
    case "${f##*/}" in
        test-*) continue ;;
    esac
    awk -v file="$f" '
        function inspect() {
            if (buf ~ /(^|[ \t;&|(])gh[ \t]+api([ \t]|$)/ &&
                buf ~ /\|\|[ \t]*(true|echo)([ \t;)&|"'"'"']|$)/) {
                printf "%s:%d: gh api exit status masked -- test it directly (if out=\"$(gh api ...)\"; then)\n", \
                    file, start > "/dev/stderr"
                bad = 1
            }
        }
        {
            trimmed = $0
            sub(/^[ \t]+/, "", trimmed)
            # A full-line comment outside a continuation is prose, not code --
            # the fixed call sites quote the bad shape to explain it.
            if (buf == "" && trimmed ~ /^#/) next
            if (buf == "") start = FNR
            buf = buf " " trimmed
            # Keep accumulating while the command clearly continues.
            if ($0 ~ /\\[ \t]*$/) next
            if ($0 ~ /(\||&&)[ \t]*$/) next
            inspect()
            buf = ""
        }
        END { if (buf != "") inspect(); exit bad }
    ' "$f" || status=1
done

exit "$status"
