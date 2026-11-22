#!/bin/bash
# Refuses a tree in which a Scripts/test-*.sh suite is not run, on every pull
# request, by a step whose failure fails the build.
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
# So "named in a workflow" is not the rule, and neither is "named in ci.yml":
# the first version of this guard counted any run: block in ci.yml, and a
# review of PR #473 moved a suite into each of four places where it would
# never fail a pull request and got a pass every time. A suite counts only on
# a line of its own in a `run:` block that is all of these:
#
#   - in ci.yml, the one workflow that runs on every pull request;
#   - in a job the `testflight` job needs. Scripts/check-release-gate.sh
#     --print-needs is what says which jobs those are, and that guard already
#     refuses a needed job with an `if:` or `continue-on-error` of its own.
#     This one refuses them too, so it does not depend on running second. A job
#     the release does not wait for (changed-paths, revyl-main) is off or
#     push-only, and does not count;
#   - in a step with no `if:`, no `continue-on-error` other than false, no
#     `shell:` other than bash or sh (a custom one can drop `-e`) -- its own,
#     or one set by `defaults: run: shell:` on its job or the workflow -- and
#     no `set` that turns errexit off (`set +e`, `set +x +e`, `set +xe`,
#     `set +o errexit`) in its script;
#   - starting its line, with nothing piped, chained with `||`, or backgrounded
#     after it: `Scripts/test-x.sh || true`, `... | tee` (no pipefail under the
#     default shell) and `echo Scripts/test-x.sh` all run nothing that can fail.
#
# A comment never counts: a whole-line or trailing comment inside the run
# block, a YAML comment, a step's `name:`.
#
# A suite that genuinely cannot run on a runner goes on EXEMPT below with its
# reason. An exemption naming a suite that no longer exists is refused too, so
# the list cannot silently outlive what it excuses.
#
# The parser reads ci.yml's own layout (two-space indents: jobs at 2, job keys
# at 4, steps at 6, step keys at 8), as check-release-gate.sh does. A layout it
# cannot read makes suites look unregistered, so it fails closed, never open.
#
# Exit 0: every suite is run or exempt. Exit 1: at least one is not, each named.
# Exit 2: no suites found, or the workflow is missing, unreadable or has no
# release gate to read -- fail closed; a guard that cannot read its input has
# proved nothing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Overridable so the suite can point the check at fixtures.
SUITES_DIR="${SUITES_DIR:-$ROOT/Scripts}"
SUITE_WORKFLOW="${SUITE_WORKFLOW:-$ROOT/.github/workflows/ci.yml}"

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

# One record per command line of every run: block in the workflow:
#   <counted|uncounted> TAB <job> TAB <the line, comments removed>
# `uncounted` when the step or its job is conditional, may fail without failing
# the build, or runs its script without -e. Whether the JOB is one the release
# waits for is decided afterwards, from check-release-gate.sh.
run_lines() {
  awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function value(s) {
      sub(/^[^:]*:[ \t]*/, "", s); sub(/[ \t]+#.*$/, "", s)
      gsub(/["\047]/, "", s); return s
    }
    # Does a `set` line turn errexit off? `+e` may share its token with other
    # flags (`+xe`) or follow them (`set +x +e`), and `+o errexit` may follow
    # `-x`; the flag being first is not the rule.
    function plus_e(s,   n, t, i) {
      sub(/[;&|].*$/, "", s)
      n = split(s, t, /[ \t]+/)
      for (i = 2; i <= n; i++) {
        if (t[i] ~ /^\+[A-Za-z]*e[A-Za-z]*$/) return 1
        if (t[i] == "+o" && t[i + 1] == "errexit") return 1
      }
      return 0
    }
    function emit(s) {
      sub(/^[ \t]+/, "", s)
      if (s == "" || s ~ /^#/) return
      sub(/[ \t]+#.*$/, "", s)
      if (s ~ /^set[ \t]/ && plus_e(s)) stepbad = 1
      stepbuf = stepbuf job "\t" s "\n"
    }
    function endstep() {
      if (instep) {
        n = split(stepbuf, ls, "\n")
        for (i = 1; i <= n; i++)
          if (ls[i] != "") { nl++; lbad[nl] = stepbad; ltext[nl] = ls[i] }
      }
      instep = 0; stepbad = 0; stepbuf = ""; inblock = 0
    }
    # A job-level if: or continue-on-error may come after its steps, so the
    # verdict on each line is settled only when the job ends.
    # A workflow-level `defaults:` may come after `jobs:`, so nothing is
    # printed until END.
    function endjob() {
      endstep()
      for (i = 1; i <= nl; i++) { no++; obad[no] = (lbad[i] || jobbad); otext[no] = ltext[i] }
      job = ""; jobbad = 0; nl = 0; insteps = 0; injdefaults = 0
    }
    # `defaults: run: shell:` sets the shell of every step under it that has
    # no `shell:` of its own. Anything but bash or sh can drop -e (`bash {0}`).
    function bad_shell(line) {
      if (line !~ /^[ ]+shell:/) return 0
      v = value(line)
      return (v != "bash" && v != "sh")
    }
    {
      if (inblock) {
        if ($0 ~ /^[ \t]*$/) next
        if (indent($0) > keycol) { emit($0); next }
        inblock = 0
      }
      if ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*#/) next
      if ($0 ~ /^jobs:[ \t]*(#.*)?$/) { injobs = 1; next }
      if ($0 ~ /^[^ ]/) { endjob(); injobs = 0; intopdefaults = ($0 ~ /^defaults:/); next }
      if (!injobs) { if (intopdefaults && bad_shell($0)) wfbad = 1; next }
      line = $0
      if (line ~ /^  [^ ]/) {
        endjob()
        job = line; sub(/^  /, "", job); sub(/:.*$/, "", job); gsub(/["\047]/, "", job)
        next
      }
      if (job == "") next
      if (line ~ /^    [^ ]/) {
        endstep()
        key = line; sub(/^    /, "", key); sub(/:.*$/, "", key)
        insteps = (key == "steps")
        injdefaults = (key == "defaults")
        if (key == "if") jobbad = 1
        if (key == "continue-on-error" && value(line) != "false") jobbad = 1
        next
      }
      if (injdefaults && bad_shell(line)) jobbad = 1
      if (!insteps) next
      if (line ~ /^      - /) {
        endstep(); instep = 1
        sub(/^      - /, "        ", line)
      }
      if (!instep) next
      if (line ~ /^        [A-Za-z0-9_-]+:/) {
        key = line; sub(/^        /, "", key); sub(/:.*$/, "", key)
        v = value(line)
        if (key == "if") stepbad = 1
        else if (key == "continue-on-error" && v != "false") stepbad = 1
        else if (key == "shell" && v != "bash" && v != "sh") stepbad = 1
        else if (key == "run") {
          if (v ~ /^[|>][-+0-9]*$/) { inblock = 1; keycol = 8 }
          else emit(v)
        }
      }
    }
    END {
      endjob()
      for (i = 1; i <= no; i++)
        printf "%s\t%s\n", ((obad[i] || wfbad) ? "uncounted" : "counted"), otext[i]
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

if [ ! -r "$SUITE_WORKFLOW" ]; then
  echo "error: cannot read workflow $SUITE_WORKFLOW" >&2
  exit 2
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# The jobs the release waits for. A failure here is not "no jobs": it is a
# workflow with no gate to read, and nothing below could be trusted.
if ! RELEASE_GATE_CI_FILE="$SUITE_WORKFLOW" "$ROOT/Scripts/check-release-gate.sh" --print-needs \
    > "$TMPD/needs" 2> "$TMPD/needs.err"; then
  echo "error: could not read the release gate's jobs from $SUITE_WORKFLOW: $(cat "$TMPD/needs.err")" >&2
  exit 2
fi
if [ ! -s "$TMPD/needs" ]; then
  echo "error: the release in $SUITE_WORKFLOW waits for no job, so no suite can count as run" >&2
  exit 2
fi
NEEDED=" $(tr '\n' ' ' < "$TMPD/needs")"

run_lines "$SUITE_WORKFLOW" > "$TMPD/lines"
: > "$TMPD/counted"
: > "$TMPD/anywhere"
while IFS="$(printf '\t')" read -r verdict job text; do
  printf '%s\n' "$text" >> "$TMPD/anywhere"
  case "$NEEDED" in *" $job "*) ;; *) continue ;; esac
  if [ "$verdict" = counted ]; then printf '%s\n' "$text" >> "$TMPD/counted"; fi
done < "$TMPD/lines"

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
  name="${s//./\\.}"
  # Runs it: its own command, optional plain arguments, and nothing after
  # that could swallow its exit status.
  runs="^(\./)?Scripts/${name}([[:space:]][^|&;]*)?$"
  # Mentions it anywhere in a run: block, for a better error message only.
  mentions="(^|[^A-Za-z0-9_./-])(\./)?Scripts/${name}([^A-Za-z0-9_.-]|$)"
  if grep -Eq "$runs" "$TMPD/counted"; then
    echo "ok - $s"
  elif grep -Eq "$mentions" "$TMPD/anywhere"; then
    echo "error: Scripts/$s is named in $SUITE_WORKFLOW, but not where its failure fails every pull request: it is in a job the release does not wait for, a step with an if:, continue-on-error or a custom shell, or a line that masks its exit status. Run it on a line of its own in the 'Verify the build-script helpers' step" >&2
    status=1
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
