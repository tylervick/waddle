#!/bin/bash
# Tests for Scripts/duo-pose-device-hub.sh.
#
# HERMETIC: `orca` and `xcrun` are stubs. The orca stub serves Device Hub's
# accessibility tree from a fixture, in the shape read from the real window on
# 2026-11-20, and logs every click; the xcrun stub plays `simctl list devices`
# and `devicectl device orientation get`. Nothing here touches Device Hub, a
# simulator or the pointer.
#
# What the suite is for: the hook presses buttons that fold WHICHEVER
# simulator is selected, on a Mac other sessions share. So most cases are
# about it pressing nothing unless it has found its own device, and about it
# saying why when it stops.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

HOOK="$ROOT/Scripts/duo-pose-device-hub.sh"
MINE="AAAAAAAA-0000-0000-0000-000000000001"
OTHER="BBBBBBBB-0000-0000-0000-000000000002"

# Fresh world per case. $1 = sidebar rows, one "index|text" per line; the
# buttons under the device are always there, at 87 to 90 as in the real tree.
setup() {
    rm -rf "$TMP/w"; mkdir -p "$TMP/w/bin"
    W="$TMP/w"
    : > "$W/clicks"
    echo portrait > "$W/orientation"
    {
        printf '0 standard window Devices\n\t4 list Sidebar\n'
        printf '%s\n' "$1" | while IFS='|' read -r index text; do
            [ -n "$index" ] && printf '\t\t%s outline row %s\n\t\t\t%s cell %s\n' "$index" "$text" "$((index + 1))" "$text"
        done
        printf '\t87 button Rotate Right\n\t88 button Closed\n\t89 button Partially Open\n\t90 button Open\n'
    } > "$W/tree"
    cat > "$W/simctl-list" <<LIST
== Devices ==
-- iOS 27.1 --
    iPhone Duo ($MINE) (Booted) 
    iPhone Duo review417 ($OTHER) (Booted) 
LIST
    cat > "$W/bin/orca" <<'STUB'
#!/bin/bash
W="$(cd "$(dirname "$0")/.." && pwd)"
[ "$1 $2" = "computer get-app-state" ] && {
    python3 -c 'import json, sys; print(json.dumps({"ok": True, "result": {"snapshot": {"treeText": open(sys.argv[1]).read()}}}))' "$W/tree"
    exit 0
}
[ "$1 $2" = "computer click" ] && {
    while [ $# -gt 0 ]; do [ "$1" = --element-index ] && index="$2"; shift; done
    echo "$index" >> "$W/clicks"
    # Rotate Right: a quarter turn, as devicectl then reports it.
    if [ "$index" = 87 ]; then
        case "$(cat "$W/orientation")" in
            portrait) echo landscapeRight ;; landscapeRight) echo portraitUpsideDown ;;
            portraitUpsideDown) echo landscapeLeft ;; *) echo portrait ;;
        esac > "$W/orientation.new" && mv "$W/orientation.new" "$W/orientation"
    fi
    echo '{"ok": true}'
    exit 0
}
echo "orca stub: unexpected call: $*" >&2; exit 97
STUB
    cat > "$W/bin/xcrun" <<'STUB'
#!/bin/bash
W="$(cd "$(dirname "$0")/.." && pwd)"
[ "$1 $2 $3" = "simctl list devices" ] && { cat "$W/simctl-list"; exit 0; }
[ "$1 $2 $3 $4" = "devicectl device orientation get" ] && {
    [ -e "$W/devicectl-fails" ] && { echo "ERROR: The device is not available." >&2; exit 1; }
    [ -e "$W/devicectl-silent" ] && exit 0
    echo "Current Device Orientation: $(cat "$W/orientation")"; exit 0
}
echo "xcrun stub: unexpected call: $*" >&2; exit 97
STUB
    chmod +x "$W/bin/orca" "$W/bin/xcrun"
}

run() { # pose [udid] [name]
    set +e
    OUT="$(PATH="$W/bin:$PATH" ORCA_CLI_COMMAND="$W/bin/orca" DUO_POSE_SETTLE=0 \
        "$HOOK" "$1" "${2:-$MINE}" "${3:-iPhone Duo}" 2>&1)"
    RC=$?
    set -e
}
clicks() { paste -sd' ' - < "$W/clicks"; }

ROWS='8|iPhone 18 Pro 27.0 Simulator
14|iPhone Duo 27.1 Simulator'

# 1. Open: selects its own row, presses Open, and turns nothing when the
#    device is already upright.
setup "$ROWS"; run open
[ "$RC" = 0 ] || fail "open exited $RC: $OUT"
[ "$(clicks)" = "14 90" ] || fail "open pressed '$(clicks)', expected the row (14) then Open (90)"
pass "open selects its own row and presses Open"

# 2. Half open: open, a quarter turn read back from devicectl, then the hinge.
setup "$ROWS"; run half-open
[ "$RC" = 0 ] || fail "half-open exited $RC: $OUT"
[ "$(clicks)" = "14 90 87 89" ] || fail "half-open pressed '$(clicks)', expected 14 90 87 89"
echo "$OUT" | grep -q "devicectl reads landscapeRight" || fail "half-open did not report the turn: $OUT"
pass "half-open opens, turns once and presses Partially Open"

# 3. Closed, from the turned pose: three more quarter turns to upright, then
#    Closed. The turn is read back, not counted.
setup "$ROWS"; echo landscapeRight > "$W/orientation"; run closed
[ "$RC" = 0 ] || fail "closed exited $RC: $OUT"
[ "$(clicks)" = "14 87 87 87 88" ] || fail "closed pressed '$(clicks)', expected 14 87 87 87 88"
pass "closed turns back to upright before closing"

# 4. A selected row still matches.
setup '14|(selected) iPhone Duo 27.1 Simulator'; run open
[ "$RC" = 0 ] && [ "$(clicks)" = "14 90" ] || fail "a selected row was not found (exit $RC, clicks '$(clicks)'): $OUT"
pass "an already selected row is found"

# 5. Another simulator whose name BEGINS with this one's is not this one,
#    wherever it sits in the list. This is the shared-Mac case: the first
#    matching row used to win.
setup '8|iPhone Duo review417 27.1 Simulator
14|iPhone Duo 27.1 Simulator
20|iPhone Duo 2 27.1 Simulator'; run open
[ "$RC" = 0 ] || fail "open exited $RC with a longer-named neighbour: $OUT"
[ "$(clicks)" = "14 90" ] || fail "pressed '$(clicks)' with a longer-named neighbour first in the list, expected 14 90"
pass "a longer name that begins the same way is a different row"

# 6. Only the neighbour is listed: nothing is pressed.
setup '8|iPhone Duo review417 27.1 Simulator'; run open
[ "$RC" != 0 ] || fail "pressed on with only another simulator in the list"
[ ! -s "$W/clicks" ] || fail "pressed '$(clicks)' although its own row was missing"
echo "$OUT" | grep -q "shows no simulator row named 'iPhone Duo'" || fail "wrong refusal: $OUT"
pass "a missing row presses nothing"

# 7. Two rows read exactly alike: refuse rather than take the first.
setup '8|iPhone Duo 27.1 Simulator
14|iPhone Duo 27.1 Simulator'; run open
[ "$RC" != 0 ] || fail "chose between two identical rows"
[ ! -s "$W/clicks" ] || fail "pressed '$(clicks)' with two identical rows"
echo "$OUT" | grep -q "shows 2 of simulator row" || fail "wrong refusal: $OUT"
pass "two matching rows press nothing"

# 8. The name must be this UDID's, and nobody else's, before the tree is even
#    read: Device Hub shows names only.
setup "$ROWS"; echo "    iPhone Duo ($OTHER) (Shutdown) " >> "$W/simctl-list"; run open
[ "$RC" != 0 ] || fail "accepted a name two simulators share"
[ ! -s "$W/clicks" ] || fail "pressed '$(clicks)' with a shared name"
echo "$OUT" | grep -q "does not identify simulator $MINE alone" || fail "wrong refusal: $OUT"
setup "$ROWS"; run open "$OTHER" "iPhone Duo"
[ "$RC" != 0 ] || fail "accepted a name that belongs to another UDID"
[ ! -s "$W/clicks" ] || fail "pressed '$(clicks)' for another UDID's name"
setup "$ROWS"; run open "$MINE" "No Such Simulator"
[ "$RC" != 0 ] && [ ! -s "$W/clicks" ] || fail "accepted a name simctl does not list"
pass "a name that is not this UDID's alone presses nothing"

# 9. devicectl failing is said out loud, with what it printed, and is not
#    read as "turn again". Likewise an answer with no orientation in it.
setup "$ROWS"; touch "$W/devicectl-fails"; run half-open
[ "$RC" != 0 ] || fail "went on although devicectl failed"
echo "$OUT" | grep -q "devicectl could not read the orientation of $MINE" || fail "devicectl's failure was not reported: '$OUT'"
echo "$OUT" | grep -q "The device is not available" || fail "devicectl's own message was dropped: $OUT"
! grep -q '^87$' "$W/clicks" || fail "turned the device although its orientation was unreadable"
setup "$ROWS"; touch "$W/devicectl-silent"; run half-open
[ "$RC" != 0 ] || fail "went on although devicectl gave no orientation"
echo "$OUT" | grep -q "devicectl gave no orientation" || fail "the empty answer was not reported: '$OUT'"
! grep -q '^87$' "$W/clicks" || fail "turned the device on an empty answer"
pass "an unreadable orientation fails loudly and turns nothing"

# 10. A turn that never arrives stops after four presses.
setup "$ROWS"; echo faceUp > "$W/orientation"
sed -i.bak 's/if \[ "\$index" = 87 \]/if false/' "$W/bin/orca"; run half-open
[ "$RC" != 0 ] || fail "a turn that never read back did not fail"
[ "$(grep -c '^87$' "$W/clicks")" = 4 ] || fail "expected four Rotate Right presses, got $(grep -c '^87$' "$W/clicks")"
echo "$OUT" | grep -q "four quarter turns never read" || fail "wrong failure: $OUT"
pass "a turn that never reads back stops after four presses"

# 11. An unknown pose is refused before anything is pressed.
setup "$ROWS"; run sideways
[ "$RC" != 0 ] || fail "accepted an unknown pose"
[ ! -s "$W/clicks" ] || fail "pressed '$(clicks)' for an unknown pose"
pass "an unknown pose presses nothing"

echo "All duo-pose-device-hub tests passed."
