#!/bin/bash
# Prints one red-green verdict for the diff between a base ref and HEAD:
# whether the tests shipped with a change actually fail without that change.
#
# Verdicts: proved | proved-by-compile | vacuous | no-test | n/a | error
# See docs/superpowers/specs/2026-08-10-test-proof-signal-design.md.
#
# `error` means the proof could not be computed. It never means "bad", and it
# is never folded into a score -- see docs/learnings/masked-exit-status-fails-open.md
# for why this repo treats an absent measurement as absent.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BASE_REF="${1:-origin/main}"

# Mutating a dirty tree could not be reliably undone, and this script's whole
# job is to mutate and restore. Refuse rather than risk the owner's work.
if [ -n "$(git status --porcelain)" ]; then
    echo "error: refusing to run against a dirty working tree; commit or stash first" >&2
    exit 1
fi

BASE="$(git merge-base HEAD "$BASE_REF")"
changed="$(git diff --name-only "$BASE" HEAD)"

# Domain membership. Printed one path per line; empty output means the domain
# has no files of that kind in this diff.
swift_src()  { printf '%s\n' "$changed" | grep -E '^App/Sources/.*\.swift$'        || true; }
swift_test() { printf '%s\n' "$changed" | grep -E '^App/Tests/.*\.swift$'          || true; }
shell_src()  { printf '%s\n' "$changed" | grep -E '^Scripts/[^/]*\.sh$' | grep -v '^Scripts/test-' || true; }
shell_test() { printf '%s\n' "$changed" | grep -E '^Scripts/test-[^/]*\.sh$'       || true; }

# One domain's verdict, given its source and test file lists. Task 3 and Task 4
# replace the `run_*` calls; until then a domain with both halves is `error`,
# which is honest -- nothing has been proved yet.
classify_domain() { # name, src, test
    if [ -z "$2" ]; then echo "absent"; return; fi
    if [ -z "$3" ]; then echo "no-test"; return; fi
    echo "error"
}

sw="$(classify_domain swift "$(swift_src)" "$(swift_test)")"
sh="$(classify_domain shell "$(shell_src)" "$(shell_test)")"

if [ "$sw" = "absent" ] && [ "$sh" = "absent" ]; then
    echo "n/a"
    exit 0
fi
# Single-domain case only until Task 5 adds combination.
if [ "$sw" != "absent" ]; then echo "$sw"; else echo "$sh"; fi
