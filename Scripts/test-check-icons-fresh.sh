#!/bin/bash
# Tests for Scripts/check-icons-fresh.sh.
#
# Fully HERMETIC: builds a fake repo in a temp dir and runs the guard there.
# Nothing here touches the real Design/ tree.
#
# Only the TOOLLESS paths are exercised -- --sync-only and the missing-file
# refusals. The full mode shells out to extract-mark.py, which needs uv,
# potrace, and a real 1254x1254 render; standing that up in a fixture would test
# the extractor rather than the guard, and CI runs --sync-only anyway. The full
# mode's own success path is covered by `mise run check-icons` on a clean tree.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# Fake repo mirroring the layout the guard walks. Contents are arbitrary -- the
# guard compares bytes, it never decodes an image.
make_fixture() { # dest
    mkdir -p "$1/Scripts" "$1/Design/source" "$1/App/AppIcon.icon/Assets"
    cp "$ROOT/Scripts/check-icons-fresh.sh" "$1/Scripts/"
    printf 'source-render'   > "$1/Design/source/waddle-logo.png"
    printf 'mark-bytes'      > "$1/Design/waddle-mark.png"
    printf '<svg/>'          > "$1/Design/waddle-mark-flat.svg"
    printf 'mark-bytes'      > "$1/App/AppIcon.icon/Assets/mark.png"
}
# ${2-...} not ${2:-...}: the colon form substitutes on empty AS WELL AS unset,
# so passing "" to select full mode would silently become --sync-only and the
# full-mode cases below would test nothing.
check() { "$1/Scripts/check-icons-fresh.sh" "${2---sync-only}"; }

# 1. Everything in sync -> pass silently.
make_fixture "$TMP/a"
check "$TMP/a" > "$TMP/out" 2>&1 || fail "rejected an in-sync tree"
[ -s "$TMP/out" ] && fail "printed output on the success path"
pass "passes silently when the package copy matches"

# 2. Package copy drifted from Design/ -> refuse, and say how to fix it.
make_fixture "$TMP/b"; printf 'drifted' > "$TMP/b/App/AppIcon.icon/Assets/mark.png"
if check "$TMP/b" > "$TMP/out" 2>&1; then fail "passed with a drifted package copy"; fi
grep -q "mise run icons" "$TMP/out" || fail "drift error lacks regeneration guidance"
pass "fails closed when the .icon copy drifts"

# 3. Each required file missing in turn -> refuse. A guard that passes because
#    its inputs vanished is worse than no guard.
for missing in Design/source/waddle-logo.png Design/waddle-mark.png \
               Design/waddle-mark-flat.svg App/AppIcon.icon/Assets/mark.png; do
    make_fixture "$TMP/c"; rm "$TMP/c/$missing"
    if check "$TMP/c" > "$TMP/out" 2>&1; then fail "passed with $missing absent"; fi
    grep -q "is missing" "$TMP/out" || fail "absent $missing did not report a missing file"
done
pass "fails closed when any required file is absent"

# 4. --sync-only must not need uv or potrace: it runs in CI before the toolchain
#    exists. Strip PATH to the system bins so neither can be found.
make_fixture "$TMP/d"
if ! PATH="/usr/bin:/bin" check "$TMP/d" > "$TMP/out" 2>&1; then
    fail "--sync-only needs tooling that CI will not have: $(cat "$TMP/out")"
fi
pass "--sync-only runs with no uv and no potrace on PATH"

# 5. The full mode must NOT silently downgrade to --sync-only when the tools are
#    missing -- that would quietly narrow the guarantee to the one thing it can
#    still check. Refuse and name the flag instead.
make_fixture "$TMP/e"
if PATH="/usr/bin:/bin" check "$TMP/e" "" > "$TMP/out" 2>&1; then
    fail "full mode passed without uv/potrace instead of refusing"
fi
grep -q -- "--sync-only" "$TMP/out" || fail "refusal does not point at --sync-only"
pass "full mode refuses rather than downgrading when tooling is absent"

# 6. Unknown arguments are rejected, so a typo'd flag cannot read as the default.
make_fixture "$TMP/f"
if check "$TMP/f" "--syncnoly" > "$TMP/out" 2>&1; then fail "accepted an unknown flag"; fi
grep -q "usage:" "$TMP/out" || fail "unknown flag did not print usage"
pass "rejects unknown arguments"

echo "all check-icons-fresh tests passed"
