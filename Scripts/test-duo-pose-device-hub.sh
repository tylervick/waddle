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

# HOOK names the script under test, so a deliberately broken copy can be run
# through the same cases to show that they fail.
HOOK="${HOOK:-$ROOT/Scripts/duo-pose-device-hub.sh}"
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
[ "$1 $2" = "computer list-windows" ] && { cat "$W/windows"; exit 0; }
[ "$1 $2" = "computer click" ] && {
    while [ $# -gt 0 ]; do [ "$1" = --element-index ] && index="$2"; shift; done
    echo "$index" >> "$W/clicks"
    # A press on a sidebar row selects it, and the tree says so, as the real
    # one does: "outline row (selected) <name> ...". `steal-after` holds a
    # number of presses after which someone else selects row 8 instead.
    python3 - "$W/tree" "$index" <<'PY'
import re, sys
path, index = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
if any(re.match(r"\s*%s outline row " % index, l) for l in lines):
    lines = [l.replace("outline row (selected) ", "outline row ") for l in lines]
    lines = [re.sub(r"^(\s*%s outline row )" % index, r"\1(selected) ", l) for l in lines]
    open(path, "w").write("\n".join(lines))
PY
    if [ -e "$W/steal-after" ] && [ "$(wc -l < "$W/clicks" | tr -d ' ')" -ge "$(cat "$W/steal-after")" ]; then
        sed -i.bak -e 's/outline row (selected) /outline row /' -e 's/\(8 outline row \)/\1(selected) /' "$W/tree"
    fi
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
    # Device Hub's one window, where it was on 2026-11-20, and a timed-drag
    # that only writes down what it was asked to post.
    echo '{"ok": true, "result": {"windows": [{"id": 215, "x": 314, "y": 175, "width": 1100, "height": 800, "app": {"pid": 3972}}]}}' > "$W/windows"
    printf '#!/bin/bash\necho "$*" >> "%s/drags"\n' "$W" > "$W/bin/timed-drag"
    : > "$W/drags"
    chmod +x "$W/bin/orca" "$W/bin/xcrun" "$W/bin/timed-drag"
}

run() { # pose [udid] [name]
    set +e
    OUT="$(PATH="$W/bin:$PATH" ORCA_CLI_COMMAND="$W/bin/orca" DUO_POSE_SETTLE=0 \
        DUO_HUB_LOCK="$W/lock" DUO_HUB_LOCK_WAIT="${LOCK_WAIT:-5}" \
        "$HOOK" "$1" "${2:-$MINE}" "${3:-iPhone Duo}" 2>&1)"
    RC=$?
    set -e
}
clicks() { paste -sd' ' - < "$W/clicks"; }
run_touch() { # window, waypoints...
    set +e
    OUT="$(PATH="$W/bin:$PATH" ORCA_CLI_COMMAND="$W/bin/orca" DUO_POSE_SETTLE=0 DUO_TIMED_DRAG="$W/bin/timed-drag" \
        DUO_HUB_LOCK="$W/lock" DUO_HUB_LOCK_WAIT="${LOCK_WAIT:-5}" \
        "$HOOK" touch "$MINE" "iPhone Duo" "$@" 2>&1)"
    RC=$?
    set -e
}

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

setup "$ROWS"; run open-turned
[ "$RC" = 0 ] || fail "open-turned exited $RC: $OUT"
[ "$(clicks)" = "14 90 87" ] || fail "open-turned pressed '$(clicks)', expected 14 90 87"
echo "$OUT" | grep -q "devicectl reads landscapeRight" || fail "open-turned did not report the turn: $OUT"
pass "open-turned opens and turns once, and leaves the device flat"

setup "$ROWS"; run closed-turned
[ "$RC" = 0 ] || fail "closed-turned exited $RC: $OUT"
[ "$(clicks)" = "14 88 87" ] || fail "closed-turned pressed '$(clicks)', expected 14 88 87"
echo "$OUT" | grep -q "devicectl reads landscapeRight" || fail "closed-turned did not report the turn: $OUT"
pass "closed-turned closes and turns once"

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

# 12. A touch: the device's row is selected, and the waypoints go from the
#     app's points to the screen's, through where the window is and where the
#     display is drawn in it. Wide: 314 + 418 + 100 * 0.529, 175 + 227 + 200 * 0.529.
setup "$ROWS"; run_touch wide 0,0,80 100,200,500
[ "$RC" = 0 ] || fail "touch exited $RC: $OUT"
[ "$(clicks)" = "14" ] || fail "touch pressed '$(clicks)', expected only its own row (14)"
[ "$(cat "$W/drags")" = "3972 215 314 175 732.0,402.0,80 784.9,507.8,500" ] \
    || fail "touch posted '$(cat "$W/drags")'"
pass "a touch selects its own row and posts the path in screen points"

# 13. The tall window is drawn somewhere else, and the bent one is squashed.
setup "$ROWS"; run_touch tall 0,0,80
[ "$(cat "$W/drags")" = "3972 215 314 175 807.0,327.0,80" ] || fail "tall touch posted '$(cat "$W/drags")'"
setup "$ROWS"; run_touch tall-bent 100,100,80
[ "$(cat "$W/drags")" = "3972 215 314 175 857.8,394.2,80" ] || fail "bent touch posted '$(cat "$W/drags")'"
pass "each window shape has its own place for the display"

# 14. The display's place was measured in a window of one size. In any
#     other, a touch would land somewhere unmeasured, so none is made.
setup "$ROWS"; sed -i.bak 's/"width": 1100/"width": 1400/' "$W/windows"; run_touch wide 10,10,80
[ "$RC" != 0 ] || fail "aimed a touch in a window of another size"
echo "$OUT" | grep -q "1400x800" || fail "the refusal did not name the window's size: $OUT"
[ ! -s "$W/drags" ] || fail "posted '$(cat "$W/drags")' in a window of another size"
pass "a window of another size gets no touch"

# 15. A waypoint that is not x,y,ms is refused before anything is pressed.
for bad in 10,10 10,10,80,5 ten,10,80 '10,10,80;rm' ''; do
    setup "$ROWS"; run_touch wide "$bad"
    [ "$RC" != 0 ] || fail "accepted the waypoint '$bad'"
    [ ! -s "$W/clicks" ] && [ ! -s "$W/drags" ] || fail "acted on the waypoint '$bad'"
done
setup "$ROWS"; run_touch sideways 10,10,80
[ "$RC" != 0 ] && [ ! -s "$W/drags" ] || fail "accepted an unknown window shape"
pass "a malformed touch presses and posts nothing"

# 16. A touch is aimed at whichever simulator is selected, so it too stops
#     when its own row cannot be told from another's.
setup '8|iPhone Duo 27.1 Simulator
14|iPhone Duo 27.1 Simulator'; run_touch wide 10,10,80
[ "$RC" != 0 ] || fail "touched although two rows carry the name"
[ ! -s "$W/drags" ] || fail "posted '$(cat "$W/drags")' with two rows by the name"
pass "a touch is not made when the row is ambiguous"

# 17. The selection is someone else's by the time the button would be
#     pressed: another session selected its own row after this one selected
#     ours. The button folds whichever row is selected, so it is not pressed.
setup "$ROWS"; echo 1 > "$W/steal-after"; run open
[ "$RC" != 0 ] || fail "pressed Open although the selection had moved"
[ "$(clicks)" = "14" ] || fail "pressed '$(clicks)' after losing the selection, expected only the row (14)"
echo "$OUT" | grep -q "no longer the simulator selected" || fail "the lost selection was not reported: $OUT"
pass "a selection lost before the first button presses no button"

# 18. Lost in the middle of a pose, after Open: the turn is not pressed.
setup "$ROWS"; echo 2 > "$W/steal-after"; run half-open
[ "$RC" != 0 ] || fail "went on although the selection moved after Open"
[ "$(clicks)" = "14 90" ] || fail "pressed '$(clicks)', expected the row and Open and nothing after"
pass "a selection lost mid-pose stops the pose there"

# 19. A touch is posted to whatever the window shows, so it is checked last.
setup "$ROWS"; echo 1 > "$W/steal-after"; run_touch wide 10,10,80
[ "$RC" != 0 ] || fail "posted a touch although the selection had moved"
[ ! -s "$W/drags" ] || fail "posted '$(cat "$W/drags")' at another session's simulator"
pass "a selection lost before a touch posts no touch"

# --- the lock ---------------------------------------------------------------
#
# The lock is the kernel's (flock, through lockf(1)), so what is tested here
# is the hook's use of it: that it waits a bounded time and then presses
# nothing, that it holds the lock for exactly one invocation, and that
# nothing a dead holder leaves behind can keep the next one out.
command -v lockf >/dev/null || fail "this machine has no lockf(1), which the hook's lock is made of"
free() { lockf -s -t 0 "$1" true; }  # true if nobody holds the lock on that file

# 20. Held by a live process, the hook waits its time out and presses
#     nothing. A `lockf` of the suite's own stands in for the other session.
setup "$ROWS"; lockf -k "$W/lock" sleep 30 & HOLDER=$!
until [ -e "$W/lock" ] && ! free "$W/lock"; do sleep 0.05; done
LOCK_WAIT=1 run open
[ "$RC" != 0 ] || fail "went ahead while another session held Device Hub"
[ ! -s "$W/clicks" ] || fail "pressed '$(clicks)' while another session held Device Hub"
echo "$OUT" | grep -q "another session has held Device Hub" || fail "the held lock was not reported: $OUT"
! free "$W/lock" || fail "a waiter that timed out took the lock from its holder"
pkill -P "$HOLDER" 2>/dev/null || true; kill "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true
pass "a lock held by a live process is waited for, then nothing is pressed"

# 21. A lock file nobody holds is no lock: one left by a holder that is gone
#     does not delay the next run. And the lock is free again at the end,
#     after success and after failure alike.
setup "$ROWS"; : > "$W/lock"; LOCK_WAIT=1 run open
[ "$RC" = 0 ] || fail "a leftover lock file stopped the hook: $OUT"
[ "$(clicks)" = "14 90" ] || fail "pressed '$(clicks)' past a leftover lock file"
free "$W/lock" || fail "the lock was still held after a successful run"
setup "$ROWS"; echo 1 > "$W/steal-after"; run open
[ "$RC" != 0 ] && free "$W/lock" || fail "the lock was still held after a failed run"
pass "a leftover lock file holds nobody out, and the lock is released on every way out"

# 22. A refusal that comes before the lock (not our simulator) takes none.
setup "$ROWS"; run open "$OTHER"
[ "$RC" != 0 ] && [ ! -e "$W/lock" ] && [ ! -s "$W/clicks" ] || fail "an ownership refusal took the lock or pressed something"
pass "an ownership refusal neither locks nor presses"

# 23. A lock path that cannot be opened (something else is there) stops the
#     hook before it presses anything. It does not go on unlocked.
setup "$ROWS"; mkdir "$W/lock"; LOCK_WAIT=1 run open
[ "$RC" != 0 ] && [ ! -s "$W/clicks" ] || fail "went on without a lock when the lock could not be opened: pressed '$(clicks)'"
echo "$OUT" | grep -q "cannot open the Device Hub lock" || fail "the unusable lock path was not reported: $OUT"
pass "a lock that cannot be opened stops the hook"

# --- the lock under contention ---------------------------------------------
#
# These run several invocations at once, with DUO_HUB_LOCK_PROBE standing in
# for the work: the hook takes the lock, runs the probe, and lets go. The
# probe is an overlap detector. It makes a directory, waits, and removes it;
# if a second holder is inside at the same moment its `mkdir` fails, and that
# is written down.
probe_world() {
    setup "$ROWS"
    : > "$W/overlaps"; : > "$W/finished"
    cat > "$W/bin/probe" <<PROBE
#!/bin/bash
mkdir "$W/inside" 2>/dev/null || { echo "\$\$" >> "$W/overlaps"; exit 0; }
sleep 0.05
rmdir "$W/inside"
echo "\$\$" >> "$W/finished"
PROBE
    # `exec`, so the holder's work is one process: the lock is the kernel's
    # and lasts as long as anything still has the descriptor, a grandchild
    # left behind included.
    printf '#!/bin/bash\nexec sleep 60\n' > "$W/bin/hang"
    chmod +x "$W/bin/probe" "$W/bin/hang"
}
contend() {  # probe program; runs in the background, prints nothing
    PATH="$W/bin:$PATH" ORCA_CLI_COMMAND="$W/bin/orca" DUO_POSE_SETTLE=0 \
        DUO_HUB_LOCK="$W/lock" DUO_HUB_LOCK_WAIT="$((30 + ${QUEUE_SECONDS:-2}))" DUO_HUB_LOCK_PROBE="$1" \
        "$HOOK" open "$MINE" "iPhone Duo" >> "$W/contend.log" 2>&1 &
}
# A real invocation takes the lock and sits in it; `kill_the_holder` then
# kills it outright, with SIGKILL, and whatever it was running.
HELD_BY=""
start_a_holder() {
    local n=0
    contend "$W/bin/hang"; HELD_BY=$!
    until [ -e "$W/lock" ] && ! free "$W/lock"; do
        n=$((n + 1)); [ "$n" -lt 200 ] || fail "the holder never took the lock: $(cat "$W/contend.log")"
        sleep 0.05
    done
}
kill_the_holder() {
    pkill -9 -P "$HELD_BY" 2>/dev/null || true
    kill -9 "$HELD_BY" 2>/dev/null || true
    wait "$HELD_BY" 2>/dev/null || true
}
check_round() {  # what the round was, for messages
    OVERLAPS=$((OVERLAPS + $(wc -l < "$W/overlaps")))
    UNFINISHED=$((UNFINISHED + WAITERS - $(wc -l < "$W/finished")))
    free "$W/lock" || fail "$1: the lock was still held when everyone had gone"
}

# 24. Waiters behind a holder that is already dead. One at a time, and every
#     one of them gets its turn. A lock made of links and pids failed this
#     (each waiter read the dead pid, the first cleared the lock and took it,
#     and the next cleared THAT); 12 rounds of 8 caught that in 4 runs of 6.
#     STRESS_ROUNDS and STRESS_WAITERS turn it up for a longer look.
ROUNDS="${STRESS_ROUNDS:-12}"; WAITERS="${STRESS_WAITERS:-8}"
OVERLAPS=0; UNFINISHED=0
for round in $(seq 1 "$ROUNDS"); do
    probe_world; start_a_holder; kill_the_holder
    for _ in $(seq 1 "$WAITERS"); do contend "$W/bin/probe"; done
    wait
    check_round "round $round behind a dead holder"
done
[ "$OVERLAPS" = 0 ] || fail "$OVERLAPS pairs of holders were inside the lock together, in $ROUNDS rounds of $WAITERS waiters behind a dead holder"
[ "$UNFINISHED" = 0 ] || fail "$UNFINISHED waiters never got the lock, in $ROUNDS rounds of $WAITERS behind a dead holder: $(tail -3 "$W/contend.log")"
pass "behind a dead holder, waiters take the lock one at a time and all get it ($ROUNDS rounds of $WAITERS)"

# 25. Waiters that have ALREADY QUEUED behind a live holder when it is
#     killed, and have been queued a while. The link-and-pid lock's last
#     failure was here: it dated a waiter's claim from when the waiter
#     started waiting, so after 30 s in the queue each live waiter took the
#     others' claims for abandoned and two of them took the lock (16 of 120
#     rounds, third review of pull request 421). Nothing here counts time
#     any more, so a short queue is the same test as a long one; the wait is
#     QUEUE_SECONDS, for anyone who wants the 33 s of that review.
QUEUED="${QUEUE_SECONDS:-2}"; QUEUE_ROUNDS="${QUEUE_ROUNDS:-4}"
OVERLAPS=0; UNFINISHED=0
for round in $(seq 1 "$QUEUE_ROUNDS"); do
    probe_world; start_a_holder
    for _ in $(seq 1 "$WAITERS"); do contend "$W/bin/probe"; done
    sleep "$QUEUED"
    [ ! -s "$W/finished" ] && [ ! -s "$W/overlaps" ] || fail "a waiter got in while the holder was alive"
    kill_the_holder
    wait
    check_round "round $round, queued ${QUEUED}s"
done
[ "$OVERLAPS" = 0 ] || fail "$OVERLAPS pairs of holders were inside the lock together after queueing ${QUEUED}s behind a holder that was then killed"
[ "$UNFINISHED" = 0 ] || fail "$UNFINISHED waiters never got the lock after queueing ${QUEUED}s behind a holder that was then killed: $(tail -3 "$W/contend.log")"
pass "waiters queued ${QUEUED}s behind a holder that is then killed go one at a time and all get the lock ($QUEUE_ROUNDS rounds of $WAITERS)"

# 26. The control: the same crowd with nobody ahead of it.
probe_world; OVERLAPS=0; UNFINISHED=0
for _ in $(seq 1 "$WAITERS"); do contend "$W/bin/probe"; done
wait
check_round "the control"
[ "$OVERLAPS" = 0 ] && [ "$UNFINISHED" = 0 ] || fail "with nobody ahead: $OVERLAPS overlaps, $UNFINISHED unfinished"
pass "the same waiters with nobody ahead of them also go one at a time"

echo "All duo-pose-device-hub tests passed."
