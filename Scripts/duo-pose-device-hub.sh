#!/bin/bash
# Puts an iPhone Duo simulator in a pose by pressing Device Hub's buttons
# through Orca's desktop control. It is the WADDLE_DUO_POSE_HOOK that
# `Scripts/capture-screenshots.sh capture duo-inner` runs (issue #409):
#
#   WADDLE_DUO_POSE_HOOK=Scripts/duo-pose-device-hub.sh \
#       Scripts/capture-screenshots.sh capture duo-inner
#
#   Scripts/duo-pose-device-hub.sh <open|open-turned|half-open|closed|closed-turned> <udid> <simulator name>
#
#   open       open flat, held upright: the app's window is wide (951x669 pt)
#   open-turned  open flat, turned a quarter turn: the window is tall
#              (669x951 pt). Scripts/duo-layout-sweep.sh asks for it (issue #357)
#   half-open  turned a quarter turn and standing half open: the window is
#              tall and the fold runs across it
#   closed     upright and closed, as a simulator boots
#   closed-turned  closed and turned a quarter turn: the outer display in
#              landscape (678x466 pt). `devicectl device orientation set`
#              turns a closed Duo on a headless CI runner, but on a Mac with
#              Device Hub running it reported success and changed nothing
#              (2026-11-20), so the sweep turns it here
#
# It also makes one touch on the open inner display, for the gestures a UI
# test cannot synthesize there (a drag or a long press does nothing on an
# open Duo; Scripts/duo-layout-sweep.sh asks for them, issue #357):
#
#   Scripts/duo-pose-device-hub.sh touch <udid> <simulator name> <wide|tall|tall-bent> <x,y,ms> [<x,y,ms> ...]
#
# The waypoints are in the APP'S points: the finger goes down at the first
# and stays for its ms, then reaches each later one over that one's ms, and
# lifts at the last. `wide` or `tall` is the shape of the app's window, which
# decides where Device Hub draws the display; `tall-bent` is the tall window
# on a device standing half open. The picture's place in the
# window is a measurement (DISPLAY_* below), good only for Device Hub's
# default 1100x800 window at zoom-to-fit, so any other window size is refused.
# The path is posted by timed-drag.c, which rides private interfaces; see
# the learning for why Orca's own drag will not do.
#
# Two sessions must not work Device Hub at once, and neither may act on the
# other's simulator. The buttons and a touch go to whichever row is SELECTED,
# and selecting is a separate press from acting. So:
#   * One invocation at a time holds a kernel lock on a file every session
#     on this Mac agrees on (DUO_HUB_LOCK). A holder is waited for,
#     DUO_HUB_LOCK_WAIT seconds, and then this stops having pressed nothing;
#     a holder that has died holds nothing. See `lock`.
#   * The lock binds only callers of this script. A person, or a session
#     with an older copy, can still change the selection. So immediately
#     before every press of a device button, and before a touch is posted,
#     the tree is read again and this simulator's row must be the one marked
#     selected. If it is not, nothing more is pressed.
# What remains is the time between that read and the press, a fraction of a
# second, against someone who is not using the lock.
#
# Nothing Apple ships folds the simulator from a script; the hinge and the
# rotate button exist only in Device Hub's window
# (docs/learnings/driving-device-hub-by-desktop-control.md). So this needs
# what that file lists: Orca with its accessibility permission, Device Hub
# running with its window on a Space Orca has seen, and an UNLOCKED Mac. It
# acts in the background; it does not bring the window forward.
#
# It presses buttons by NAME, looked up fresh before each press: element
# indexes do not survive a change of selection. Device Hub's tree does not
# carry a simulator's UDID. A sidebar row reads "<name> <iOS version>
# Simulator", so the device is found by that whole line, and only when it can
# be nobody else's: `simctl` must know exactly one device by that name, it
# must be the UDID asked for, and exactly one row must match. A shared Mac
# has other workers' simulators in the same list ("iPhone Duo" is also how
# "iPhone Duo of someone else" begins), and the buttons fold whichever row is
# selected. Anything short of one match presses nothing. It reads the device's
# orientation back from devicectl, because Rotate Right is relative and
# `devicectl device orientation set` reports success and changes nothing on
# an open Duo. The hinge has no read-back here; the caller checks the pose
# its own way (the inner display lit, the app's half-open marker).
set -euo pipefail

ORCA="${ORCA_CLI_COMMAND:-orca}"
# What devicectl calls the two ways up this script uses. One press of Rotate
# Right from upright reads landscapeRight (measured 2026-11-20).
DUO_UPRIGHT="portrait"
DUO_TURNED="landscapeRight"
APP="com.apple.dt.Devices"
# How long a fold or a turn is given to finish before the next read.
SETTLE="${DUO_POSE_SETTLE:-1.5}"
# One path for every session on the Mac, so not under a per-session TMPDIR.
LOCK="${DUO_HUB_LOCK:-/tmp/waddle-device-hub.flock}"
LOCK_WAIT="${DUO_HUB_LOCK_WAIT:-120}"
case "$LOCK_WAIT" in ''|*[!0-9]*) echo "DUO_HUB_LOCK_WAIT must be a whole number of seconds, got '$LOCK_WAIT'" >&2; exit 2 ;; esac
# Where Device Hub draws the open inner display, in window points: the window
# size this holds for, the screen points per app point, and the display's
# top-left corner when the app's window is wide (951x669) and when it is tall
# (669x951). Measured 2026-11-20 from a screenshot of the window.
# Each is "x y x-scale y-scale". A device standing half open is drawn in
# perspective, shorter than it is flat, so `tall-bent` is a straight-line
# fit to a picture that is not quite straight: good to about ten app points,
# which is enough for a row or a button and not for anything finer.
DISPLAY_WINDOW="1100 800"
DISPLAY_WIDE="418 227 0.529 0.529"
DISPLAY_TALL="493 152 0.529 0.529"
DISPLAY_TALL_BENT="490 170 0.538 0.492"

usage() {
    echo "usage: $0 <open|open-turned|half-open|closed|closed-turned> <udid> <simulator name>" >&2
    echo "       $0 touch <udid> <simulator name> <wide|tall|tall-bent> <x,y,ms> [<x,y,ms> ...]" >&2
    exit 2
}
[ $# -ge 3 ] || usage
POSE="$1"; UDID="$2"; NAME="$3"
case "$POSE" in
    open|open-turned|half-open|closed|closed-turned) [ $# -eq 3 ] || usage ;;
    touch)
        [ $# -ge 5 ] || usage
        WINDOW="$4"; shift 4
        case "$WINDOW" in wide|tall|tall-bent) ;; *) echo "the window is 'wide', 'tall' or 'tall-bent', not '$WINDOW'" >&2; exit 2 ;; esac
        for point in "$@"; do
            case "$point" in
                *[!0-9,.]*|,*|*,|*,,*) echo "bad waypoint '$point' (want x,y,ms)" >&2; exit 2 ;;
                *,*,*,*) echo "bad waypoint '$point' (want x,y,ms)" >&2; exit 2 ;;
                *,*,*) ;;
                *) echo "bad waypoint '$point' (want x,y,ms)" >&2; exit 2 ;;
            esac
        done
        ;;
    *) echo "unknown pose '$POSE' (open, open-turned, half-open, closed, closed-turned, or touch)" >&2; exit 2 ;;
esac

# The element indexes of every line of Device Hub's tree that matches a
# regular expression in full, one per line, or nothing.
elements() {  # regex
    local state
    state="$("$ORCA" computer get-app-state --app "$APP" --no-screenshot --json)" \
        || { echo "error: could not read Device Hub's window (is the Mac unlocked and Device Hub running?)" >&2; return 1; }
    printf '%s' "$state" | PATTERN="$1" python3 -c '
import json, os, re, sys
doc = json.load(sys.stdin)
if not doc.get("ok"):
    sys.exit("error: " + json.dumps(doc.get("error")))
for line in doc["result"]["snapshot"]["treeText"].splitlines():
    m = re.match(r"\s*(\d+) (.*)", line)
    if m and re.fullmatch(os.environ["PATTERN"], m.group(2)):
        print(m.group(1))
'
}

press() {  # regex, what it is called in messages
    local index out count
    index="$(elements "$1")" || exit 1
    [ -n "$index" ] || { echo "error: Device Hub shows no $2" >&2; exit 1; }
    count="$(printf '%s\n' "$index" | wc -l | tr -d ' ')"
    [ "$count" = 1 ] || { echo "error: Device Hub shows $count of $2; refusing to guess which is meant" >&2; exit 1; }
    out="$("$ORCA" computer click --app "$APP" --element-index "$index" --no-screenshot --json)" \
        || { echo "error: could not press $2: $out" >&2; exit 1; }
    sleep "$SETTLE"  # the fold and the turn are animated
}

# This simulator's row in the sidebar, whole: name to "Simulator", so a
# longer name that begins the same way is a different row.
ROW_NAME="$(printf '%s' "$NAME" | sed 's/[][\\.*^$()+?{}|]/\\&/g') [0-9][0-9.]* Simulator"

# Succeeds only if this simulator's row is the selected one, read now.
selected() {
    local index
    index="$(elements "outline row \\(selected\\) $ROW_NAME")" || return 1
    [ -n "$index" ] && [ "$(printf '%s\n' "$index" | wc -l | tr -d ' ')" = 1 ]
}
require_selected() {  # what is about to be done
    selected && return 0
    echo "error: '$NAME' is no longer the simulator selected in Device Hub; not going on to $1." >&2
    echo "       Someone else changed the selection. Nothing further was pressed." >&2
    exit 1
}

# A press of one of the buttons under the device, which acts on whichever
# simulator is selected: so the selection is read again first.
act() {  # regex, what it is called in messages
    require_selected "press the $2"
    press "$1" "$2"
}

# The lock.
#
# It is a kernel lock, flock(2), on the file at $LOCK, taken with macOS's
# /usr/bin/lockf on a descriptor this shell keeps open. The kernel lets go of
# it when the last process holding that descriptor is gone, however it went:
# an exit, a failed command, a signal, SIGKILL. So there is no stale lock to
# recognise, nothing to take over, and no age to judge. The file itself is
# left in place and means nothing; only a held descriptor is a lock.
#
# This replaces a lock built from links and pids, whose takeover of a dead
# holder's lock was got wrong three ways in three reviews of pull request
# 421 (two waiters clearing the same stale lock; a lock with no pid in it;
# a live waiter's claim judged abandoned because its age was counted from
# when it started waiting). All three were in code whose only job was to do
# what the kernel does anyway.
#
# Two things to know. A program this script has started inherits the
# descriptor, so if the script is killed while one is running (a press, a
# posted touch), the lock is held until that program ends, a second or two:
# which is right, since it may still be acting on Device Hub. And the path
# is not the one the link-and-pid versions used, which could have left a
# link or a directory there; a copy of this script from before 2026-11-21
# does not see this lock at all, and against one of those the selection
# re-read above is the only guard.
lock() {
    command -v lockf >/dev/null || {
        echo "error: no lockf(1) on this machine; it is what keeps two sessions out of Device Hub at once. Nothing was pressed." >&2
        exit 1
    }
    # Appending, so that opening it never empties or replaces anything.
    exec 9>>"$LOCK" || {
        echo "error: cannot open the Device Hub lock at $LOCK; nothing was pressed." >&2
        exit 1
    }
    # Tried without waiting, and again after a pause, until the time is up.
    # `lockf -t <seconds>` would do the waiting itself, but on a descriptor
    # it spins: one waiter measured at a whole core for the length of its
    # wait (macOS 27.2, 2026-11-21), and a sweep queues hundreds of touches.
    local deadline=$((SECONDS + LOCK_WAIT))
    until lockf -s -t 0 9; do
        [ $SECONDS -lt $deadline ] || {
            echo "error: another session has held Device Hub ($LOCK) for ${LOCK_WAIT}s; nothing was pressed." >&2
            exit 1
        }
        sleep 0.2
    done
}

# Prints the device's orientation as devicectl names it. Fails, saying so,
# when devicectl fails or answers something that is not an orientation: an
# empty answer must not read as "not there yet, turn again".
orientation() {
    local out word
    out="$(xcrun devicectl device orientation get --device "$UDID" 2>&1)" \
        || { echo "error: devicectl could not read the orientation of $UDID: $out" >&2; return 1; }
    word="$(printf '%s\n' "$out" | sed -nE 's/.*[Oo]rientation: *([A-Za-z]+).*/\1/p')"
    word="${word%%$'\n'*}"
    [ -n "$word" ] || { echo "error: devicectl gave no orientation for $UDID: $out" >&2; return 1; }
    printf '%s\n' "$word"
}

# Rotate Right is a quarter turn each press; four come back to the start.
turn_to() {  # the orientation wanted, as devicectl names it
    local n=0 now
    while :; do
        now="$(orientation)" || exit 1
        [ "$now" = "$1" ] && return 0
        [ "$n" -lt 4 ] || { echo "error: four quarter turns never read '$1' (devicectl says '${now:-nothing}')" >&2; exit 1; }
        act 'button Rotate Right$' "Rotate Right button"
        n=$((n + 1))
    done
}

# Which simulator: the name must be this UDID's and nobody else's.
SIMCTL_LIST="$(xcrun simctl list devices)" || { echo "error: simctl could not list the simulators" >&2; exit 1; }
OWNERS="$(printf '%s\n' "$SIMCTL_LIST" | NAME="$NAME" python3 -c '
import os, re, sys
# "    <name> (<UDID>) (<state>)", read from the right: a name may hold parentheses.
for line in sys.stdin:
    m = re.match(r"\s+(.*) \(([0-9A-F-]{36})\) \([^()]*\)\s*$", line)
    if m and m.group(1) == os.environ["NAME"]:
        print(m.group(2))
')"
[ "$OWNERS" = "$UDID" ] || {
    echo "error: the name '$NAME' does not identify simulator $UDID alone; simctl lists it for: $(echo ${OWNERS:-no device})" >&2
    echo "       Device Hub shows names, not UDIDs, so give the simulator a name no other has." >&2
    exit 1
}

# Everything a touch needs that takes time is done BEFORE the row is selected
# (and outside the lock): the build of timed-drag once took half a minute.
if [ "$POSE" = touch ]; then
    # DUO_TIMED_DRAG names a built timed-drag (the tests name a stub).
    DRAG="${DUO_TIMED_DRAG:-}"
    SOURCE="$(dirname "$0")/../docs/learnings/assets/duo-device-hub-2026-11-20/timed-drag.c"
    if [ -z "$DRAG" ]; then
        DRAG="${TMPDIR:-/tmp}/waddle-timed-drag"
        if [ ! -x "$DRAG" ] || [ "$SOURCE" -nt "$DRAG" ]; then
            # Built beside its place and moved in, so a second invocation
            # never runs half a binary.
            xcrun clang -O2 "$SOURCE" -o "$DRAG.$$" -framework ApplicationServices \
                -F/System/Library/PrivateFrameworks -framework SkyLight \
                && mv -f "$DRAG.$$" "$DRAG" \
                || { rm -f "$DRAG.$$"; echo "error: could not build timed-drag" >&2; exit 1; }
        fi
    fi
fi

lock

# For the suite's stress case, which is about the lock and nothing else:
# with the lock held, run the named program in place of everything below.
if [ -n "${DUO_HUB_LOCK_PROBE:-}" ]; then
    "$DUO_HUB_LOCK_PROBE"
    exit $?
fi

# Select the device first: the buttons act on whichever is selected.
press "outline row (\\(selected\\) )?$ROW_NAME" "simulator row named '$NAME'"

if [ "$POSE" = touch ]; then
    WINDOWS="$("$ORCA" computer list-windows --app "$APP" --json)" \
        || { echo "error: could not list Device Hub's windows (is the Mac unlocked and Device Hub running?)" >&2; exit 1; }
    # pid, window id, and the window's frame on the screen.
    GEOMETRY="$(printf '%s' "$WINDOWS" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
if not doc.get("ok"):
    sys.exit("error: " + json.dumps(doc.get("error")))
windows = doc["result"]["windows"]
if len(windows) != 1:
    sys.exit("error: Device Hub has %d windows; refusing to guess which shows the device" % len(windows))
w = windows[0]
print(w["app"]["pid"], w["id"], w["x"], w["y"], w["width"], w["height"])
')" || exit 1
    read -r HUB_PID HUB_WINDOW HUB_X HUB_Y HUB_W HUB_H <<EOF
$GEOMETRY
EOF
    [ "$HUB_W $HUB_H" = "$DISPLAY_WINDOW" ] || {
        echo "error: Device Hub's window is ${HUB_W}x${HUB_H}, and the display's place in it was measured at ${DISPLAY_WINDOW/ /x}; refusing to aim a touch by it" >&2
        exit 1
    }
    case "$WINDOW" in wide) PLACE="$DISPLAY_WIDE" ;; tall) PLACE="$DISPLAY_TALL" ;; tall-bent) PLACE="$DISPLAY_TALL_BENT" ;; esac
    # App points to screen points.
    PATH_ARGS="$(HUB_X="$HUB_X" HUB_Y="$HUB_Y" PLACE="$PLACE" python3 -c '
import os, sys
ox, oy, kx, ky = (float(v) for v in os.environ["PLACE"].split())
hx, hy = float(os.environ["HUB_X"]), float(os.environ["HUB_Y"])
for point in sys.argv[1:]:
    x, y, ms = (float(v) for v in point.split(","))
    print("%.1f,%.1f,%d" % (hx + ox + x * kx, hy + oy + y * ky, ms))
' "$@")" || exit 1
    # The touch lands on whatever the window shows, so this is the last
    # thing before it.
    require_selected "post the touch"
    # shellcheck disable=SC2086
    "$DRAG" "$HUB_PID" "$HUB_WINDOW" "$HUB_X" "$HUB_Y" $PATH_ARGS \
        || { echo "error: timed-drag failed" >&2; exit 1; }
    echo "touch on $NAME ($WINDOW window): $*"
    exit 0
fi

case "$POSE" in
    open)
        act 'button Open$' "Open button"
        turn_to "$DUO_UPRIGHT"
        ;;
    open-turned)
        act 'button Open$' "Open button"
        turn_to "$DUO_TURNED"
        ;;
    half-open)
        act 'button Open$' "Open button"
        turn_to "$DUO_TURNED"
        act 'button Partially Open$' "Partially Open button"
        ;;
    closed)
        turn_to "$DUO_UPRIGHT"
        act 'button Closed$' "Closed button"
        ;;
    closed-turned)
        act 'button Closed$' "Closed button"
        turn_to "$DUO_TURNED"
        ;;
esac
NOW="$(orientation)" || exit 1
echo "pose '$POSE' asked of Device Hub for $NAME; devicectl reads $NOW"
