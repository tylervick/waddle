#!/bin/bash
# Tests for Scripts/check-icons-fresh.sh.
#
# Fully HERMETIC: builds a fake repo in a temp dir and runs the guard there.
# Nothing here touches the real Design/ tree.
#
# Only the TOOLLESS paths are exercised -- --sync-only and the missing-file
# refusals. The full mode shells out to build-mark.py, which needs uv and the
# real glyph PNGs; standing that up in a fixture would test the compositor
# rather than the guard, and CI runs --sync-only anyway. The full mode's own
# success path is covered by `mise run check-icons` on a clean tree, and the
# compositors by Scripts/test-build-mark.sh and Scripts/test-build-duck.sh.
# Neither of those runs in CI: both need uv, which the runner does not have.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# Fake repo mirroring the layout the guard walks. Contents are arbitrary -- the
# guard compares bytes, it never decodes an image.
#
# Both derivations are present: the Freedoom glyphs still produce the wordmark,
# and Design/source/duck/ produces the duck the app icon shows. The package
# copy is seeded from the DUCK, because that is what icon.json points at.
make_fixture() { # dest
    mkdir -p "$1/Scripts" "$1/Design/source/freedoom-glyphs" "$1/Design/source/duck" \
             "$1/App/AppIcon.icon/Assets"
    cp "$ROOT/Scripts/check-icons-fresh.sh" "$1/Scripts/"
    for g in W A D L E; do printf 'glyph' > "$1/Design/source/freedoom-glyphs/$g.png"; done
    printf 'duck-grid'       > "$1/Design/source/duck/duck-66px.png"
    printf 'mark-bytes'      > "$1/Design/waddle-mark.png"
    printf '<svg/>'          > "$1/Design/waddle-mark-flat.svg"
    printf 'duck-bytes'      > "$1/Design/waddle-duck.png"
    printf '<svg id="d"/>'   > "$1/Design/waddle-duck-flat.svg"
    printf 'duck-bytes'      > "$1/App/AppIcon.icon/Assets/duck.png"
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
make_fixture "$TMP/b"; printf 'drifted' > "$TMP/b/App/AppIcon.icon/Assets/duck.png"
if check "$TMP/b" > "$TMP/out" 2>&1; then fail "passed with a drifted package copy"; fi
grep -q "mise run icons" "$TMP/out" || fail "drift error lacks regeneration guidance"
pass "fails closed when the .icon copy drifts"

# 3. Each required file missing in turn -> refuse. A guard that passes because
#    its inputs vanished is worse than no guard.
for missing in Design/source/freedoom-glyphs/W.png Design/source/freedoom-glyphs/E.png \
               Design/source/duck/duck-66px.png \
               Design/waddle-mark.png Design/waddle-mark-flat.svg \
               Design/waddle-duck.png Design/waddle-duck-flat.svg \
               App/AppIcon.icon/Assets/duck.png; do
    make_fixture "$TMP/c"; rm "$TMP/c/$missing"
    if check "$TMP/c" > "$TMP/out" 2>&1; then fail "passed with $missing absent"; fi
    grep -q "is missing" "$TMP/out" || fail "absent $missing did not report a missing file"
done
pass "fails closed when any required file is absent"

# 4. --sync-only must not need uv: it runs in CI before the toolchain
#    exists. Strip PATH to the system bins so neither can be found.
make_fixture "$TMP/d"
if ! PATH="/usr/bin:/bin" check "$TMP/d" > "$TMP/out" 2>&1; then
    fail "--sync-only needs tooling that CI will not have: $(cat "$TMP/out")"
fi
pass "--sync-only runs with no uv on PATH"

# 5. The full mode must NOT silently downgrade to --sync-only when the tools are
#    missing -- that would quietly narrow the guarantee to the one thing it can
#    still check. Refuse and name the flag instead.
make_fixture "$TMP/e"
if PATH="/usr/bin:/bin" check "$TMP/e" "" > "$TMP/out" 2>&1; then
    fail "full mode passed without uv instead of refusing"
fi
grep -q -- "--sync-only" "$TMP/out" || fail "refusal does not point at --sync-only"
pass "full mode refuses rather than downgrading when tooling is absent"

# 6. Unknown arguments are rejected, so a typo'd flag cannot read as the default.
make_fixture "$TMP/f"
if check "$TMP/f" "--syncnoly" > "$TMP/out" 2>&1; then fail "accepted an unknown flag"; fi
grep -q "usage:" "$TMP/out" || fail "unknown flag did not print usage"
pass "rejects unknown arguments"

# 7. The package must track the DUCK, not the wordmark. Seeding the package
#    copy from waddle-mark.png is the exact mistake a half-finished rename
#    leaves behind, and it would otherwise sail through: both files exist, both
#    derivations still verify, and only this comparison notices that the icon
#    is showing the wrong artwork.
make_fixture "$TMP/g"
cp "$TMP/g/Design/waddle-mark.png" "$TMP/g/App/AppIcon.icon/Assets/duck.png"
if check "$TMP/g" > "$TMP/out" 2>&1; then
    fail "passed with the package copy taken from the wordmark, not the duck"
fi
grep -q "waddle-duck.png" "$TMP/out" \
    || fail "wrong-artwork error does not name Design/waddle-duck.png"
pass "fails closed when the package copy tracks the wordmark instead of the duck"

# 8. A stale mark.png left in Assets/ after the rename is caught by
#    check-icon-json.sh, not here -- this guard never enumerates the directory.
#    Pinned so a future reader does not add a redundant check to the wrong file:
#    the orphan-asset rule lives in check-icon-json.sh and is tested there.
make_fixture "$TMP/h"; cp "$TMP/h/Design/waddle-mark.png" "$TMP/h/App/AppIcon.icon/Assets/mark.png"
check "$TMP/h" > "$TMP/out" 2>&1 || fail "a stray Assets/mark.png broke this guard"
pass "ignores a stray asset, which is check-icon-json.sh's job"

echo "all check-icons-fresh tests passed"
