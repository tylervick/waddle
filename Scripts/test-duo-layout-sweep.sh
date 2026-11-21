#!/bin/bash
# Tests for Scripts/duo-layout-sweep.sh.
#
# HERMETIC: `xcrun`, `xcodebuild` and the pose hook are stubs. The xcodebuild
# stub plays the UI test's side of the request file (a per-case `client`
# script), the xcrun stub plays simctl, devicectl and swiftc, and the hook
# stub writes down what it was asked. No simulator, no Device Hub, no build.
#
# What the suite is for. The sweep changes a simulator's text size,
# reinstalls the app on it and folds it in a Device Hub other sessions share,
# so most cases are about whose simulator it will touch, and about what it
# leaves behind when it stops early. The rest pin the request protocol, where
# an answer that arrived late used to cost the next request.
#
# SWEEP names the script under test, so a deliberately broken copy can be run
# through the same cases to show that they fail.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWEEP="${SWEEP:-$ROOT/Scripts/duo-layout-sweep.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

MINE="AAAAAAAA-0000-0000-0000-000000000001"
OTHER="BBBBBBBB-0000-0000-0000-000000000002"

# Fresh world per case.
setup() {
    rm -rf "$TMP/w"; mkdir -p "$TMP/w/bin" "$TMP/w/wads/scythe" "$TMP/w/wads/sunlust/sunlust" \
        "$TMP/w/wads/eviternityii" "$TMP/w/Waddle.app" "$TMP/w/container/Documents"
    W="$TMP/w"
    : > "$W/calls"; : > "$W/hook"; : > "$W/client.log"
    echo portrait > "$W/orientation"
    touch "$W/wads/scythe/SCYTHE.WAD" "$W/wads/sunlust/sunlust/sunlust.wad" "$W/wads/eviternityii/Eviternity II.wad"
    cat > "$W/simctl-list" <<LIST
== Devices ==
-- iOS 27.1 --
    iPhone Duo ($OTHER) (Booted)
    Duo of mine ($MINE) (Booted)
LIST
    cat > "$W/bin/xcrun" <<'STUB'
#!/bin/bash
W="$(cd "$(dirname "$0")/.." && pwd)"
echo "$*" >> "$W/calls"
png() {  # path, width, height: enough of a PNG for its size to be read
    python3 -c 'import sys; open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR" + int(sys.argv[2]).to_bytes(4, "big") + int(sys.argv[3]).to_bytes(4, "big"))' "$@"
}
case "$1 $2" in
    "simctl list") cat "$W/simctl-list"; exit 0 ;;
    "simctl get_app_container") echo "$W/container"; exit 0 ;;
    "simctl launch")
        # The app adopts the loose map sets: they leave Documents.
        [ -e "$W/never-adopts" ] || rm -f "$W/container/Documents/"*
        exit 0 ;;
    "simctl install") [ -e "$W/install-fails" ] && exit 1; exit 0 ;;
    "simctl io")
        for a in "$@"; do path="$a"; case "$a" in --display=*) display="${a#--display=}" ;; esac; done
        [ -e "$W/shots-fail" ] && exit 1
        if [ -e "$W/shot-size" ]; then read -r w h < "$W/shot-size"
        elif [ "$display" = LCD ]; then w=1398; h=2034
        else w=2853; h=2007; fi
        png "$path" "$w" "$h"; exit 0 ;;
    "simctl "*) exit 0 ;;
    "swiftc "*)
        # Stands in for opaque-png: copies, and turns nothing.
        for a in "$@"; do out="$a"; done
        printf '#!/bin/bash\ncp "$1" "$2"\n' > "$out"; chmod +x "$out"; exit 0 ;;
esac
if [ "$1 $2 $3" = "devicectl device orientation" ]; then
    if [ "$4" = set ]; then echo "$7" > "$W/orientation"; echo "New Device Orientation: $7"; exit 0; fi
    echo "Current Device Orientation: $(cat "$W/orientation")"; exit 0
fi
echo "xcrun stub: unexpected call: $*" >&2; exit 97
STUB
    # The UI test's side: asks for things through the request file, by the
    # protocol DuoLayoutSweepTests.ask uses, and writes down what happened.
    cat > "$W/bin/xcodebuild" <<'STUB'
#!/bin/bash
W="$(cd "$(dirname "$0")/.." && pwd)"
echo "xcodebuild $*" >> "$W/calls"
REQUEST="$TEST_RUNNER_WADDLE_DUO_SWEEP_REQUEST"
N=0
ask() {  # what, seconds to wait
    N=$((N + 1)); local id="req-$$-$N" deadline=$((SECONDS + $2))
    rm -f "$REQUEST"
    printf '%s %s' "$id" "$1" > "$REQUEST.staged"; mv "$REQUEST.staged" "$REQUEST"
    while [ "$(cat "$REQUEST.done" 2>/dev/null)" != "$id" ]; do
        if [ $SECONDS -ge $deadline ]; then rm -f "$REQUEST"; echo "unanswered: $1" >> "$W/client.log"; return 1; fi
        sleep 0.05
    done
    rm -f "$REQUEST"; echo "answered: $1" >> "$W/client.log"
}
raw() {  # a line with no id, as an old or broken client would write it
    printf '%s' "$1" > "$REQUEST.staged"; mv "$REQUEST.staged" "$REQUEST"; sleep "$2"; rm -f "$REQUEST"
}
. "$W/client"
STUB
    cat > "$W/bin/hook" <<'STUB'
#!/bin/bash
W="$(cd "$(dirname "$0")/.." && pwd)"
echo "$*" >> "$W/hook"
[ "$(cat "$W/hook-fails-on" 2>/dev/null)" = "$1" ] && { echo "hook stub: failing on $1" >&2; exit 1; }
case "$1" in
    touch) sleep "$(cat "$W/slow-touch" 2>/dev/null || echo 0)" ;;
    closed|open) echo portrait > "$W/orientation" ;;
    *) echo landscapeRight > "$W/orientation" ;;
esac
exit 0
STUB
    chmod +x "$W/bin/xcrun" "$W/bin/xcodebuild" "$W/bin/hook"
    # Every shot the sweep expects, unless the case says otherwise.
    cat > "$W/client" <<'CLIENT'
for s in 01-import-banner 02-shelf 03-tile-menu 04-game-page 05-game-page-lower 06-rename-prompt-keyboard \
    07-delete-confirmation 10-settings 12-files 13-hidden-games 14-about 15-control-feel 17-layout-editor \
    20-session 21-engine-menu 22-engine-save-list 23-engine-save-name-keyboard 24-engine-quit-prompt \
    30-engine-error-box 31-launcher-error-alert 40-document-picker 50-shelf-continue-hero; do
    ask "shot $s" 10
done
CLIENT
}

# run <args to the sweep>, with NAME and HOOK from the caller's environment.
run() {
    set +e
    OUT="$(PATH="$W/bin:$PATH" \
        WADDLE_DUO_SIMULATOR="${NAME-Duo of mine}" WADDLE_DUO_POSE_HOOK="${HOOK-}" \
        WADDLE_DUO_SWEEP_OUT="$W/out" WADDLE_DUO_SWEEP_SIZES="${SIZES:-large}" \
        WADDLE_DUO_SWEEP_APP="$W/Waddle.app" WADDLE_TEST_WADS="$W/wads" \
        WADDLE_DUO_SWEEP_ADOPT_WAIT="${ADOPT_WAIT:-10}" WADDLE_DUO_SWEEP_ONLY="${ONLY-}" \
        "$SWEEP" "$@" 2>&1)"
    RC=$?
    set -e
}
hook_calls() { cut -d' ' -f1 "$W/hook" | paste -sd' ' -; }
touched_a_simulator() { grep -qE "^simctl (boot|ui|install|uninstall|io)|devicectl" "$W/calls"; }

# --- whose simulator -------------------------------------------------------

# 1. No name, no run: there is no default to fall back on.
setup; NAME="" HOOK="$W/bin/hook" run run open
[ "$RC" != 0 ] || fail "ran with no simulator named"
echo "$OUT" | grep -q "WADDLE_DUO_SIMULATOR is not set" || fail "did not say what was missing: $OUT"
! touched_a_simulator || fail "touched a simulator with none named: $(cat "$W/calls")"
[ ! -s "$W/hook" ] || fail "asked Device Hub for '$(hook_calls)' with no simulator named"
pass "no simulator named: nothing runs"

# 2. The stock name is refused even though exactly one simulator has it
#    (here, somebody else's).
setup; NAME="iPhone Duo" HOOK="$W/bin/hook" run run closed
[ "$RC" != 0 ] || fail "took the stock 'iPhone Duo' as its own"
! touched_a_simulator || fail "touched the stock simulator: $(cat "$W/calls")"
[ ! -s "$W/hook" ] || fail "folded the stock simulator: $(hook_calls)"
pass "the stock name 'iPhone Duo' is refused"

# 3. A name no simulator has, and a name two have.
setup; NAME="Duo of nobody" run run closed
[ "$RC" != 0 ] && ! touched_a_simulator || fail "ran against a name no simulator has"
setup; echo "    Duo of mine ($OTHER) (Shutdown)" >> "$W/simctl-list"; run run closed
[ "$RC" != 0 ] && ! touched_a_simulator || fail "ran against a name two simulators share"
echo "$OUT" | grep -q "more than one" || fail "the shared name was not reported: $OUT"
pass "a name that is nobody's, or two simulators', is refused"

# 4. `prepare` asks for the same.
setup; NAME="" run prepare
[ "$RC" != 0 ] || fail "prepare ran with no simulator named"
! grep -q "^xcodebuild" "$W/calls" || fail "prepare built with no simulator named"
pass "prepare needs the simulator named too"

# --- a whole run -----------------------------------------------------------

# 5. Closed, no hook: every shot is taken from the outer display on the
#    named simulator, nothing is reported missing, and the text size is put
#    back at the end.
setup; run run closed
[ "$RC" = 0 ] || fail "a clean closed run exited $RC: $OUT"
[ "$(find "$W/out/shots/closed/large" -name '*.png' | wc -l | tr -d ' ')" = 22 ] || fail "expected 22 shots: $(ls "$W/out/shots/closed/large")"
[ ! -s "$W/out/problems.txt" ] || fail "a complete run reported problems: $(cat "$W/out/problems.txt")"
grep -q "^simctl io $MINE screenshot .*--display=LCD " "$W/calls" || fail "did not photograph the outer display of the named simulator"
! grep -q "$OTHER" "$W/calls" || fail "a command named the other simulator: $(grep "$OTHER" "$W/calls")"
[ "$(grep "content_size" "$W/calls" | tail -1)" = "simctl ui $MINE content_size large" ] || fail "the text size was not put back"
grep -q "^xcodebuild .*-collect-test-diagnostics never" "$W/calls" || fail "the test session would collect diagnostics"
pass "a closed run takes every shot and puts the text size back"

# 6. An opened pose with no hook is refused before anything is installed.
setup; run run open
[ "$RC" != 0 ] || fail "ran an opened pose with nothing to open the device"
! grep -q "^simctl install" "$W/calls" || fail "installed the app for a pose it could not reach"
pass "an opened pose without a hook is refused"

# 7. Open, with the hook: asked to open, photographed from the inner
#    display, and closed again exactly once at the end.
setup; HOOK="$W/bin/hook" run run open
[ "$RC" = 0 ] || fail "a clean open run exited $RC: $OUT"
[ "$(hook_calls)" = "open closed" ] || fail "the hook was asked '$(hook_calls)', expected open then closed"
[ "$(head -1 "$W/hook")" = "open $MINE Duo of mine" ] || fail "the hook was not given the named simulator: $(head -1 "$W/hook")"
grep -q "^simctl io $MINE screenshot .*--display=LCD-1 " "$W/calls" || fail "did not photograph the inner display"
pass "an open run opens the device and closes it once at the end"

# --- what a run that stops early leaves behind -----------------------------

# 8. The hook fails after it may have pressed Open: the device is still
#    asked to close, and the text size is still put back.
setup; echo open > "$W/hook-fails-on"; HOOK="$W/bin/hook" run run open
[ "$RC" != 0 ] || fail "went on although the device could not be opened"
[ "$(hook_calls)" = "open closed" ] || fail "after a failed open the hook was asked '$(hook_calls)', expected open then closed"
grep -q "^simctl ui $MINE content_size large" "$W/calls" || fail "the text size was not put back after a failed open"
pass "a failed open still closes the device"

# 9. The map sets are never adopted, in an opened pose.
setup; touch "$W/never-adopts"; ADOPT_WAIT=1 HOOK="$W/bin/hook" run run half-open
[ "$RC" != 0 ] || fail "went on although the map sets were never adopted"
[ "$(hook_calls)" = "half-open closed" ] || fail "after a failed provision the hook was asked '$(hook_calls)'"
pass "a run that dies provisioning in an opened pose closes the device"

# 10. The install fails (errexit, not an `exit` of the script's own).
setup; touch "$W/install-fails"; HOOK="$W/bin/hook" run run open-tall
[ "$RC" != 0 ] || fail "went on although the app could not be installed"
[ "$(hook_calls)" = "open-turned closed" ] || fail "after a failed install the hook was asked '$(hook_calls)'"
pass "a run stopped by a failing command closes the device"

# 11. Interrupted. The signal is acted on when the test session returns; the
#     device is closed and the pose after this one is never started.
setup; echo 'sleep 2' > "$W/client"
set +e
PATH="$W/bin:$PATH" WADDLE_DUO_SIMULATOR="Duo of mine" WADDLE_DUO_POSE_HOOK="$W/bin/hook" \
    WADDLE_DUO_SWEEP_OUT="$W/out" WADDLE_DUO_SWEEP_SIZES=large WADDLE_DUO_SWEEP_APP="$W/Waddle.app" \
    WADDLE_TEST_WADS="$W/wads" "$SWEEP" run open half-open >/dev/null 2>&1 &
PID=$!
for _ in $(seq 1 100); do grep -q "^xcodebuild" "$W/calls" && break; sleep 0.1; done
kill -TERM "$PID"; wait "$PID"; RC=$?
set -e
[ "$RC" = 143 ] || fail "an interrupted run exited $RC, expected 143"
[ "$(hook_calls)" = "open closed" ] || fail "an interrupted run asked the hook '$(hook_calls)', expected open then closed"
pass "an interrupted run closes the device and starts no further pose"

# 12. No hook and a closed pose: nothing was opened, so the way back is
#     devicectl's, and no hook is invented.
setup; touch "$W/install-fails"; run run closed-landscape
[ "$RC" != 0 ] || fail "went on although the app could not be installed"
[ ! -s "$W/hook" ] || fail "called a hook that was never configured"
[ "$(grep "orientation set" "$W/calls" | tail -1)" = "devicectl device orientation set --device $MINE portrait" ] \
    || fail "a hookless run did not turn the device upright again: $(grep "orientation set" "$W/calls" | tail -1)"
pass "a hookless run that stops turned is turned back with devicectl"

# --- the request protocol --------------------------------------------------

# 13. The case the protocol was changed for. A touch outlives the test's
#     wait; the test gives up and asks for a shot. The late answer to the
#     touch must not count as an answer to the shot, and must not remove it.
setup; echo 3 > "$W/slow-touch"
cat > "$W/client" <<'CLIENT'
ask "touch 10,10,250" 1
ask "shot 02-shelf" 10
CLIENT
ONLY=testD_Shelf HOOK="$W/bin/hook" run run open
[ "$(cat "$W/client.log")" = "unanswered: touch 10,10,250
answered: shot 02-shelf" ] || fail "the client saw: $(cat "$W/client.log")"
[ -f "$W/out/raw/open/large/02-shelf.png" ] || fail "the shot asked for after a slow touch was never taken"
pass "a request made while a slow handler is still running is served, not swallowed"

# 14. Requests that are not requests. None of them reaches the simulator,
#     the hook, or a path outside the shots directory.
setup
cat > "$W/client" <<'CLIENT'
ask "shot ../../escaped" 5
ask "shot Bad Name" 5
ask "touch 10,10,80;touch-x" 5
ask "touch" 5
ask "format-disk now" 5
raw "shot 02-shelf" 1
ask "shot 02-shelf" 5
CLIENT
ONLY=testD_Shelf HOOK="$W/bin/hook" run run open
[ "$(find "$W/out/raw" -name '*.png' | wc -l | tr -d ' ')" = 1 ] || fail "took shots it should have refused: $(find "$W/out" -name '*.png')"
[ ! -e "$W/out/escaped.png" ] && [ ! -e "$W/escaped.png" ] || fail "a shot name walked out of the shots directory"
! grep -q "^touch" "$W/hook" || fail "passed a malformed touch to the hook: $(grep "^touch" "$W/hook")"
echo "$OUT" | grep -q "ignoring a request with no id" || fail "a request with no id was not reported: $OUT"
[ "$(tail -1 "$W/client.log")" = "answered: shot 02-shelf" ] || fail "a good request after the bad ones was not served: $(cat "$W/client.log")"
pass "malformed requests are refused and do not stop the next good one"

# 15. A touch goes to the hook with the window's shape for the pose, and
#     with no hook it is answered without one.
setup; printf 'ask "touch 10,20,250 30,40,500" 5\n' > "$W/client"
ONLY=testD_Shelf HOOK="$W/bin/hook" run run half-open
grep -qx "touch $MINE Duo of mine tall-bent 10,20,250 30,40,500" "$W/hook" || fail "the touch reached the hook as: $(grep "^touch" "$W/hook")"
pass "a touch is handed to the hook with the pose's window shape"

# 16. A shot that cannot be taken is not answered, so the test fails on it
#     by name instead of going on without the picture.
setup; touch "$W/shots-fail"; printf 'ask "shot 02-shelf" 2\n' > "$W/client"
ONLY=testD_Shelf run run closed
[ "$(cat "$W/client.log")" = "unanswered: shot 02-shelf" ] || fail "a shot that failed was answered: $(cat "$W/client.log")"
pass "a shot that cannot be taken is left unanswered"

# --- what is reported ------------------------------------------------------

# 17. A missing shot is listed; the two that exist only where a screen had
#     to be scrolled are not; taking the pose again replaces its line.
setup; printf 'ask "shot 02-shelf" 5\n' > "$W/client"; run run closed
grep -q "^closed large:.* 01-import-banner(missing)" "$W/out/problems.txt" || fail "a missing shot was not listed: $(cat "$W/out/problems.txt")"
! grep -q "02-shelf\|11-settings-lower\|16-control-feel-lower" "$W/out/problems.txt" || fail "listed a shot that is there, or an optional one"
setup; run run closed; printf 'ask "shot 02-shelf" 5\n' > "$W/client"; ONLY=testD_Shelf run run closed
[ ! -s "$W/out/problems.txt" ] || fail "a single-test retake dropped the other tests' shots: $(cat "$W/out/problems.txt")"
pass "missing shots are listed, optional ones are not, and a retake keeps the rest"

# 18. A shot of the wrong shape for the pose is listed with the shape it
#     has: that is the only check that an open pose was the pose asked for.
setup; echo "2007 2853" > "$W/shot-size"; HOOK="$W/bin/hook" run run open
grep -q "^open large:.*02-shelf(2007x2853)" "$W/out/problems.txt" || fail "a tall shot in the wide pose was not listed: $(cat "$W/out/problems.txt")"
pass "a shot the wrong shape for its pose is reported"

# 19. Closed landscape. Through the hook the device is closed, then turned,
#     and an upright 2034x1398 shot is kept as it is.
setup; echo "2034 1398" > "$W/shot-size"; HOOK="$W/bin/hook" run run closed-landscape
[ "$RC" = 0 ] || fail "closed-landscape through the hook exited $RC: $OUT"
[ "$(hook_calls)" = "closed closed-turned closed" ] || fail "the hook was asked '$(hook_calls)'"
[ ! -s "$W/out/problems.txt" ] || fail "upright landscape shots were reported: $(cat "$W/out/problems.txt")"
pass "closed landscape turns through the hook and keeps an upright shot"

# 20. An unknown pose is refused before any of it.
setup; run run sideways
[ "$RC" != 0 ] && [ ! -s "$W/calls" ] || fail "an unknown pose got as far as: $(cat "$W/calls")"
pass "an unknown pose runs nothing"

echo "All duo-layout-sweep tests passed."
