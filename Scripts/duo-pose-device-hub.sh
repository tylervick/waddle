#!/bin/bash
# Puts an iPhone Duo simulator in a pose by pressing Device Hub's buttons
# through Orca's desktop control. It is the WADDLE_DUO_POSE_HOOK that
# `Scripts/capture-screenshots.sh capture duo-inner` runs (issue #409):
#
#   WADDLE_DUO_POSE_HOOK=Scripts/duo-pose-device-hub.sh \
#       Scripts/capture-screenshots.sh capture duo-inner
#
#   Scripts/duo-pose-device-hub.sh <open|half-open|closed> <udid> <simulator name>
#
#   open       open flat, held upright: the app's window is wide (951x669 pt)
#   half-open  turned a quarter turn and standing half open: the window is
#              tall and the fold runs across it
#   closed     upright and closed, as a simulator boots
#
# Nothing Apple ships folds the simulator from a script; the hinge and the
# rotate button exist only in Device Hub's window
# (docs/learnings/driving-device-hub-by-desktop-control.md). So this needs
# what that file lists: Orca with its accessibility permission, Device Hub
# running with its window on a Space Orca has seen, and an UNLOCKED Mac. It
# acts in the background; it does not bring the window forward.
#
# It presses buttons by NAME, looked up fresh before each press: element
# indexes do not survive a change of selection. It reads the device's
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

[ $# -eq 3 ] || { echo "usage: $0 <open|half-open|closed> <udid> <simulator name>" >&2; exit 2; }
POSE="$1"; UDID="$2"; NAME="$3"

# The element index of the first line of Device Hub's tree that matches a
# regular expression, or nothing.
element() {  # regex
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
    if m and re.match(os.environ["PATTERN"], m.group(2)):
        print(m.group(1))
        break
'
}

press() {  # regex, what it is called in messages
    local index out
    index="$(element "$1")" || exit 1
    [ -n "$index" ] || { echo "error: Device Hub shows no $2" >&2; exit 1; }
    out="$("$ORCA" computer click --app "$APP" --element-index "$index" --no-screenshot --json)" \
        || { echo "error: could not press $2: $out" >&2; exit 1; }
    sleep 1.5  # the fold and the turn are animated
}

orientation() {
    xcrun devicectl device orientation get --device "$UDID" 2>/dev/null \
        | sed -nE 's/.*[Oo]rientation: *([A-Za-z]+).*/\1/p' | head -1
}

# Rotate Right is a quarter turn each press; four come back to the start.
turn_to() {  # the orientation wanted, as devicectl names it
    local n=0 now
    while :; do
        now="$(orientation)"
        [ "$now" = "$1" ] && return 0
        [ "$n" -lt 4 ] || { echo "error: four quarter turns never read '$1' (devicectl says '${now:-nothing}')" >&2; exit 1; }
        press 'button Rotate Right$' "Rotate Right button"
        n=$((n + 1))
    done
}

# Select the device first: the buttons act on whichever is selected.
press "outline row (\\(selected\\) )?$(printf '%s' "$NAME" | sed 's/[][\\.*^$()+?{}|]/\\&/g') " "simulator named '$NAME'"

case "$POSE" in
    open)
        press 'button Open$' "Open button"
        turn_to "$DUO_UPRIGHT"
        ;;
    half-open)
        press 'button Open$' "Open button"
        turn_to "$DUO_TURNED"
        press 'button Partially Open$' "Partially Open button"
        ;;
    closed)
        turn_to "$DUO_UPRIGHT"
        press 'button Closed$' "Closed button"
        ;;
    *) echo "unknown pose '$POSE' (open, half-open or closed)" >&2; exit 2 ;;
esac
echo "pose '$POSE' asked of Device Hub for $NAME; devicectl reads $(orientation)"
