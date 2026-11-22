#!/bin/bash
# Refuses a tree in which a Scripts/test-*.sh suite is run by no pull request.
#
# The incident: ci.yml's helper list said "This list must name EVERY
# Scripts/test-*.sh suite", and nothing checked the sentence. On 2026-11-22
# three suites were named in no workflow at all -- test-build-mark.sh,
# test-fetch-testflight-feedback.sh and test-glyph-source.sh, the oldest since
# 2026-08-12 -- so a change breaking any of them was green on a pull request
# and on main (issue #454). Before that, two suites had run nowhere on a pull
# request, and test-check-issue-format.sh only in issue-format.yml, which never
# triggers on one.
#
# That last case is why "named in some workflow" is not the rule. A suite
# counts only when it is named in a `run:` block of a workflow that runs on
# every pull request: ci.yml, and only ci.yml today (SUITE_WORKFLOWS below; a
# path-filtered or scheduled workflow does not count). A name in a comment, in
# a step's `name:`, or anywhere outside a `run:` block does not count either:
# a comment that mentions a suite runs nothing.
#
# A suite that genuinely cannot run on a runner goes on EXEMPT below with its
# reason. An exemption naming a suite that no longer exists is refused too, so
# the list cannot silently outlive what it excuses.
#
# Exit 0: every suite is run or exempt. Exit 1: at least one is not, each named.
# Exit 2: no suites found, or a workflow is missing or unreadable -- fail
# closed; a guard that cannot read its input has proved nothing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Overridable so the suite can point the check at fixtures. Colon-separated.
SUITES_DIR="${SUITES_DIR:-$ROOT/Scripts}"
SUITE_WORKFLOWS="${SUITE_WORKFLOWS:-$ROOT/.github/workflows/ci.yml}"

# One entry per exempt suite: "<basename>|<why it cannot run on a pull request>".
# Empty on purpose. Add to it only with the reason, and say so in the pull
# request; a suite that is merely inconvenient to run is not exempt.
EXEMPT=()
if [ -n "${SUITES_EXEMPT_FILE:-}" ]; then
  # Test hook: one entry per line, same format.
  while IFS= read -r entry || [ -n "$entry" ]; do
    if [ -n "$entry" ]; then EXEMPT+=("$entry"); fi
  done < "$SUITES_EXEMPT_FILE"
fi

# Prints the text of every `run:` block in the workflow file given, with whole-
# line comments removed and a trailing ` # comment` cut off. Handles an inline
# `run: cmd`, and a block scalar (`run: |`, `run: >-`, ...) whose body is every
# following line indented deeper than the `run` key, blank lines included.
run_text() {
  awk '
    function indent(s) { match(s, /^[ ]*/); return RLENGTH }
    function emit(s) {
      sub(/^[ \t]+/, "", s)
      if (s ~ /^#/) return
      sub(/[ \t]+#.*$/, "", s)
      print s
    }
    {
      if (inblock) {
        if ($0 ~ /^[ \t]*$/) next
        if (indent($0) > keycol) { emit($0); next }
        inblock = 0
      }
      if (match($0, /^[ ]*(- )?run:/)) {
        line = $0
        keycol = indent(line)
        if (line ~ /^[ ]*- /) keycol += 2
        rest = line
        sub(/^[ ]*(- )?run:[ \t]*/, "", rest)
        if (rest ~ /^[|>][-+0-9]*[ \t]*(#.*)?$/) { inblock = 1 }
        else if (rest != "") { emit(rest) }
      }
    }
  ' "$1"
}

suites=()
for f in "$SUITES_DIR"/test-*.sh; do
  if [ -f "$f" ]; then suites+=("$(basename "$f")"); fi
done
if [ "${#suites[@]}" -eq 0 ]; then
  echo "error: no test-*.sh suites under $SUITES_DIR -- wrong directory?" >&2
  exit 2
fi

runs="$(mktemp)"
trap 'rm -f "$runs"' EXIT
IFS=: read -r -a workflows <<< "$SUITE_WORKFLOWS"
for wf in "${workflows[@]}"; do
  if [ ! -r "$wf" ]; then
    echo "error: cannot read workflow $wf" >&2
    exit 2
  fi
  run_text "$wf" >> "$runs"
done

is_exempt() {
  local e
  for e in ${EXEMPT[@]+"${EXEMPT[@]}"}; do
    if [ "${e%%|*}" = "$1" ]; then return 0; fi
  done
  return 1
}

status=0
for s in "${suites[@]}"; do
  if is_exempt "$s"; then
    echo "exempt - $s"
    continue
  fi
  # The suite's path as a whole word: `Scripts/test-x.sh` must not be found
  # inside `Scripts/test-x.sh.bak` or `Scripts/test-x-more.sh`. The dots in the
  # name are escaped so they match only a dot.
  pattern="(^|[^A-Za-z0-9_./-])(\./)?Scripts/${s//./\\.}([^A-Za-z0-9_.-]|$)"
  if grep -Eq "$pattern" "$runs"; then
    echo "ok - $s"
  else
    echo "error: Scripts/$s is run by no pull-request workflow; add it to ci.yml's 'Verify the build-script helpers' step, or exempt it in $0 with the reason" >&2
    status=1
  fi
done

for e in ${EXEMPT[@]+"${EXEMPT[@]}"}; do
  name="${e%%|*}"
  reason="${e#*|}"
  if [ "$reason" = "$e" ] || [ -z "$reason" ]; then
    echo "error: exemption for $name gives no reason" >&2
    status=1
  fi
  if [ ! -f "$SUITES_DIR/$name" ]; then
    echo "error: exemption names $name, which is not a suite under $SUITES_DIR" >&2
    status=1
  fi
done

exit "$status"
