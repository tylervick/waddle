#!/bin/bash
# The iPhone Duo layout sweep (issue #357): photographs every surface of the
# app in each of the Duo's poses at several text sizes, for a person to look
# at. Nothing here judges a layout; the output is pictures and contact sheets.
#
# App/UITests/DuoLayoutSweepTests.swift walks the app and asks for each shot
# by name through a request file; this script serves the requests from the
# host, once per pose and text size. The test skips unless this script runs it.
#
#   Scripts/duo-layout-sweep.sh prepare             # build-for-testing
#   Scripts/duo-layout-sweep.sh run [pose ...]      # default: all five poses
#   Scripts/duo-layout-sweep.sh finish              # upright shots again, from the raw ones
#   Scripts/duo-layout-sweep.sh sheets              # contact sheets of what is there
#
# Poses, and the app's window in each:
#   closed            466x678   outer display, upright
#   closed-landscape  678x466   outer display, on its side
#   open              951x669   inner display, device upright (the window is wide)
#   open-tall         669x951   inner display, device turned a quarter turn
#   half-open         669x951   as open-tall, standing half open: the fold
#                               runs across the window
#
# Everything about the simulator that this relies on is in
# docs/learnings/iphone-duo-simulator-traps.md and
# docs/learnings/driving-device-hub-by-desktop-control.md. In short:
#   * Shots come from the host, with the display NAMED: `simctl io screenshot`
#     does not follow the active display. A shot of the outer display can be
#     the panel's own way up, and is turned here when it is (see shot_turn);
#     a shot of the inner display is upright already, and its size is the window's shape,
#     which is how an open pose is checked (the test cannot: XCUITest reports
#     the open Duo's wide window as tall).
#   * A closed device is turned by the hook where there is one and by
#     `devicectl device orientation set` where there is not (see
#     turn_closed), and again on request from the test when a launch came up
#     the wrong way.
#   * Nothing Apple ships works the hinge from a script. The three opened
#     poses need WADDLE_DUO_POSE_HOOK (Scripts/duo-pose-device-hub.sh presses
#     Device Hub's buttons through Orca's desktop control, on an unlocked Mac).
#   * A drag or long press synthesized by XCUITest does nothing on an open
#     device. The test asks for those too (`touch <x,y,ms> ...`), and the
#     same hook makes them, as `<hook> touch ...`.
#
# Each pose and size gets a fresh install, so every run meets the same
# library: the bundled games plus the three map sets of
# Scripts/provision-test-wads.sh.
#
# Env:
#   WADDLE_DUO_SIMULATOR     name of the iPhone Duo simulator to use. REQUIRED,
#                            and it has no default: this script changes the
#                            simulator's text size, reinstalls the app on it
#                            and folds it, and a name is all that says whose
#                            it is. Create one for the purpose, under a name
#                            nobody else on the Mac has. The stock name
#                            "iPhone Duo" is refused.
#   WADDLE_DUO_SWEEP_SIZES   text sizes, as `simctl ui content_size` names them
#                            (default: the default size, the largest standard
#                            size and the largest accessibility size)
#   WADDLE_DUO_SWEEP_OUT     where shots, results and sheets go
#                            (default $TMPDIR/waddle-duo-sweep)
#   WADDLE_DUO_POSE_HOOK     program run as `<hook> <pose> <udid> <name>`, and
#                            as `<hook> touch <udid> <name> <wide|tall|tall-bent>
#                            <x,y,ms> ...` for a touch on the open display
#   WADDLE_DUO_SWEEP_ONLY    test methods of DuoLayoutSweepTests to run, for
#                            taking surfaces again; the other shots are kept
#   WADDLE_TEST_WADS         the map sets, laid out as ~/Downloads/doom-test-wads
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.tylervick.waddle"
DERIVED="App/build"
APP_PATH="${WADDLE_DUO_SWEEP_APP:-$DERIVED/Build/Products/Debug-iphonesimulator/Waddle.app}"
WAD_SRC="${WADDLE_TEST_WADS:-$HOME/Downloads/doom-test-wads}"
NAME="${WADDLE_DUO_SIMULATOR:-}"
# How long the map sets are given to be adopted (the suite shortens it).
ADOPT_WAIT="${WADDLE_DUO_SWEEP_ADOPT_WAIT:-240}"
OUT="${WADDLE_DUO_SWEEP_OUT:-${TMPDIR:-/tmp}/waddle-duo-sweep}"
SIZES="${WADDLE_DUO_SWEEP_SIZES:-large extra-extra-extra-large accessibility-extra-extra-extra-large}"
POSE_HOOK="${WADDLE_DUO_POSE_HOOK:-}"
ONLY="${WADDLE_DUO_SWEEP_ONLY:-}"
ALL_POSES="closed closed-landscape open open-tall half-open"
# Every shot the test asks for, in the order the sheets show them.
SHOTS="01-import-banner 02-shelf 03-tile-menu 04-game-page 05-game-page-lower
06-rename-prompt-keyboard 07-delete-confirmation 10-settings 11-settings-lower
12-files 13-hidden-games 14-about 15-control-feel 16-control-feel-lower
17-layout-editor 20-session 21-engine-menu 22-engine-save-list
23-engine-save-name-keyboard 24-engine-quit-prompt 30-engine-error-box
31-launcher-error-alert 40-document-picker 50-shelf-continue-hero
51-game-page-continue"
# Taken only where the screen is taller than the window and had to be scrolled.
OPTIONAL_SHOTS="11-settings-lower 16-control-feel-lower"

# The one simulator this run may touch, by name. Nothing here can know whose
# a simulator is, so the caller has to say, and say it in a way that cannot
# be someone else's by accident: no default, not the name every Xcode gives
# its own Duo, and exactly one device by that name.
THE_UDID=""
require_simulator() {
    if [ -z "$NAME" ]; then
        echo "error: WADDLE_DUO_SIMULATOR is not set. Name the iPhone Duo simulator this sweep may use;" >&2
        echo "       it changes that simulator's text size, reinstalls the app on it and folds it." >&2
        echo "       xcrun simctl create '<a name of your own>' 'iPhone Duo'" >&2
        exit 2
    fi
    if [ "$NAME" = "iPhone Duo" ]; then
        echo "error: 'iPhone Duo' is the name Xcode gives the stock simulator, which may be anyone's." >&2
        echo "       Create one of your own under another name and set WADDLE_DUO_SIMULATOR to it." >&2
        exit 2
    fi
    THE_UDID="$(udid_of)"
    case "$THE_UDID" in
        '') echo "error: no available simulator is named '$NAME'" >&2; exit 1 ;;
        *$'\n'*) echo "error: more than one simulator is named '$NAME'" >&2; exit 1 ;;
    esac
}

udid_of() {
    xcrun simctl list devices available | NAME="$NAME" python3 -c '
import os, re, sys
# Read from the right: a simulator name may hold parentheses.
for line in sys.stdin:
    m = re.match(r"\s+(.*) \(([0-9A-F-]{36})\) \([^()]*\)\s*$", line)
    if m and m.group(1) == os.environ["NAME"]:
        print(m.group(2))
'
}

# Which display a pose shows, how far a host shot of it must be turned to be
# upright (clockwise), and the size the upright shot must have.
pose_display() { case "$1" in closed*) echo LCD ;; *) echo LCD-1 ;; esac; }
# How far a raw host shot must be turned, clockwise, to be upright. Only a
# closed device on its side can need it, and whether it does depends on what
# turned the device: after Device Hub's Rotate Right the outer display's shot
# comes back upright (2034x1398), and after a devicectl turn it is the
# panel's own way up (1398x2034, the picture a quarter turn clockwise, as an
# XCUIScreen shot is). So the shot's own shape decides.
shot_turn() {  # pose, raw shot
    [ "$1" = closed-landscape ] || { echo 0; return; }
    case "$(png_dims "$2")" in 1398x2034) echo 270 ;; *) echo 0 ;; esac
}
pose_pixels() {
    case "$1" in
        closed) echo 1398x2034 ;; closed-landscape) echo 2034x1398 ;;
        open) echo 2853x2007 ;; open-tall|half-open) echo 2007x2853 ;;
    esac
}
pose_window() { case "$1" in closed-landscape|open) echo wide ;; half-open) echo tall-bent ;; *) echo tall ;; esac; }

png_dims() {
    python3 -c 'import sys; d = open(sys.argv[1], "rb").read(24); print("%dx%d" % (int.from_bytes(d[16:20], "big"), int.from_bytes(d[20:24], "big")))' "$1"
}

set_pose() {  # pose, udid
    case "$1" in
        closed|closed-landscape) turn_closed "$1" "$2" ;;
        open|half-open) need_pose_hook "$1"; "$POSE_HOOK" "$1" "$2" "$NAME" >&2 ;;
        open-tall) need_pose_hook "$1"; "$POSE_HOOK" open-turned "$2" "$NAME" >&2 ;;
    esac
}
need_pose_hook() {
    [ -n "$POSE_HOOK" ] && return 0
    echo "error: pose '$1' needs the device opened, and nothing Apple ships does that from a script." >&2
    echo "       Set WADDLE_DUO_POSE_HOOK=Scripts/duo-pose-device-hub.sh (docs/learnings/driving-device-hub-by-desktop-control.md)." >&2
    exit 1
}
# Turns a closed device the way the pose wants, away and back: a device
# already the right way up would otherwise not tell an app that came up the
# wrong way. With a hook the turn is Device Hub's, because on a Mac where
# Device Hub is running `devicectl device orientation set` reports success
# and changes nothing; without one (a headless runner) devicectl does turn a
# closed Duo. Either way the result is read back.
turn_closed() {  # pose, udid
    local now
    if [ -n "$POSE_HOOK" ]; then
        if [ "$1" = closed-landscape ]; then
            "$POSE_HOOK" closed "$2" "$NAME" >&2 && "$POSE_HOOK" closed-turned "$2" "$NAME" >&2
        else
            "$POSE_HOOK" closed-turned "$2" "$NAME" >&2 && "$POSE_HOOK" closed "$2" "$NAME" >&2
        fi
    elif [ "$1" = closed-landscape ]; then
        xcrun devicectl device orientation set --device "$2" portrait >/dev/null 2>&1 || true
        sleep 1
        xcrun devicectl device orientation set --device "$2" landscapeLeft >/dev/null
    else
        xcrun devicectl device orientation set --device "$2" landscapeLeft >/dev/null 2>&1 || true
        sleep 1
        xcrun devicectl device orientation set --device "$2" portrait >/dev/null
    fi
    now="$(orientation_of "$2")"
    case "$1:$now" in
        closed:portrait|closed-landscape:landscapeLeft|closed-landscape:landscapeRight) ;;
        *) echo "error: '$NAME' reads '$now' after being turned for pose '$1'" >&2; return 1 ;;
    esac
}
orientation_of() {  # udid
    xcrun devicectl device orientation get --device "$1" 2>/dev/null \
        | sed -nE 's/.*[Oo]rientation: *([A-Za-z]+).*/\1/p' | head -1
}

# Serves the test's requests until killed.
#
# A request is one line, "<id> <what>", and is answered by writing its id to
# "<request>.done". The request file is the test's: it is never deleted
# here. It used to be, as the acknowledgement, and a handler that outlived
# the test's wait (a touch that had to compile timed-drag first) then
# deleted the NEXT request, which the test took for served. Now a late
# answer carries an id nobody is waiting for and is ignored.
#
# A shot that cannot be taken is not answered, so the test fails on it by
# name; everything else is answered whether or not it could be done, and the
# test finds out from the screen.
serve() {  # pose, udid, raw dir, request file
    local line id word rest last="" answer
    while :; do
        line="$(cat "$4" 2>/dev/null || true)"
        id="${line%% *}"
        if [ -n "$line" ] && [ "$id" != "$last" ]; then
            answer=1
            # An id is eight or more of [0-9A-Za-z-] (the test sends a
            # UUID). Anything shorter is the first word of a request written
            # without one, which must not be served under that word as its id.
            case "$id" in
                *[!0-9A-Za-z-]*|"$line"|?|??|???|????|?????|??????|???????|loose-files)
                    echo "error: ignoring a request with no id: '$line'" >&2
                    answer=""; last="$id"
                    ;;
                *) serve_one "$1" "$2" "$3" "${line#* }" || answer="" ;;
            esac
            if [ -n "$answer" ]; then
                last="$id"
                printf '%s\n' "$id" > "$4.done.new" && mv -f "$4.done.new" "$4.done"
            fi
        fi
        sleep 0.1
    done
}

# One request. Fails only when it should be asked again (a shot not taken).
serve_one() {  # pose, udid, raw dir, what
    local word="${4%% *}" rest="${4#* }"
    case "$word" in
        shot)
            case "$rest" in
                *[!0-9a-z-]*|''|shot) echo "error: refusing a shot request that is not a shot name: '$rest'" >&2 ;;
                *)
                    if xcrun simctl io "$2" screenshot --type=png --display="$(pose_display "$1")" \
                            --mask=ignored "$3/$rest.png" >/dev/null 2>&1; then
                        echo "   shot $rest" >&2
                    else
                        echo "warning: could not photograph $rest; trying again" >&2
                        sleep 1
                        return 1
                    fi
                    ;;
            esac
            ;;
        turn) turn_closed "$1" "$2" || true ;;
        touch)
            case "$rest" in
                *[!0-9,\ ]*|''|touch) echo "error: ignoring a touch request that is not waypoints: '$rest'" >&2 ;;
                *)
                    if [ -n "$POSE_HOOK" ]; then
                        # shellcheck disable=SC2086
                        "$POSE_HOOK" touch "$2" "$NAME" "$(pose_window "$1")" $rest >&2 || true
                    else
                        echo "warning: no WADDLE_DUO_POSE_HOOK to make a touch with" >&2
                    fi
                    ;;
            esac
            ;;
        loose-files) loose_files "$2" || true ;;
        *) echo "error: ignoring an unknown request: '$4'" >&2 ;;
    esac
}

provision() {  # udid: the map sets, adopted by one launch
    local docs deadline
    docs="$(xcrun simctl get_app_container "$1" "$BUNDLE_ID" data)/Documents"
    mkdir -p "$docs"
    cp "$WAD_SRC/scythe/SCYTHE.WAD" "$WAD_SRC/sunlust/sunlust/sunlust.wad" "$WAD_SRC/eviternityii/Eviternity II.wad" "$docs/"
    xcrun simctl launch "$1" "$BUNDLE_ID" >/dev/null
    deadline=$((SECONDS + ADOPT_WAIT))
    while [ -e "$docs/SCYTHE.WAD" ] || [ -e "$docs/sunlust.wad" ] || [ -e "$docs/Eviternity II.wad" ]; do
        [ $SECONDS -lt $deadline ] || { echo "error: the map sets were never adopted; left in $docs" >&2; exit 1; }
        sleep 2
    done
    sleep 3  # the library's save settles
    xcrun simctl terminate "$1" "$BUNDLE_ID" 2>/dev/null || true
}

# Three loose files for the app to adopt at its next launch, which ends with
# the longest import banner there is: an add-on, a patch, and a failure. Put
# there on request because the app's container moves when xcodebuild
# installs the app at the start of the session.
loose_files() {  # udid
    local docs
    docs="$(xcrun simctl get_app_container "$1" "$BUNDLE_ID" data)/Documents" || return 1
    mkdir -p "$docs"
    printf 'PWAD\x00\x00\x00\x00\x0c\x00\x00\x00' > "$docs/sweep-addon.wad"
    printf 'Patch File for DeHackEd v3.0\n' > "$docs/sweep-patch.deh"
    printf 'not a wad' > "$docs/sweep-broken.wad"
}

HELPER_PID=""
stop_helper() {
    [ -n "$HELPER_PID" ] || return 0
    kill "$HELPER_PID" 2>/dev/null || true
    wait "$HELPER_PID" 2>/dev/null || true
    HELPER_PID=""
}

# Turns the raw host shots of one pose and size into opaque, upright PNGs,
# and says which of them are missing or the wrong shape for the pose.
finish() {  # pose, size, raw dir, dest dir
    local shot got problems=""
    rm -rf "$4"
    mkdir -p "$4"
    for shot in $SHOTS; do
        if [ ! -f "$3/$shot.png" ]; then
            case " $OPTIONAL_SHOTS " in *" $shot "*) ;; *) problems="$problems $shot(missing)" ;; esac
            continue
        fi
        if ! "$OUT/opaque-png" "$3/$shot.png" "$4/$shot.png" "$(shot_turn "$1" "$3/$shot.png")"; then
            problems="$problems $shot(unreadable)"; continue
        fi
        got="$(png_dims "$4/$shot.png")"
        [ "$got" = "$(pose_pixels "$1")" ] || problems="$problems $shot($got)"
    done
    # One line per pose and size, replaced when that one is taken again.
    touch "$OUT/problems.txt"
    grep -v "^$1 $2:" "$OUT/problems.txt" > "$OUT/problems.txt.new" || true
    mv "$OUT/problems.txt.new" "$OUT/problems.txt"
    if [ -n "$problems" ]; then
        echo "$1 $2:$problems" >> "$OUT/problems.txt"
        echo "== $1 at $2 is incomplete:$problems" >&2
    fi
}

run_one() {  # pose, size, udid
    local raw="$OUT/raw/$1/$2" request="$OUT/request" status=0 only="" method
    for method in $ONLY; do only="$only -only-testing:WaddleUITests/DuoLayoutSweepTests/$method"; done
    [ -n "$only" ] || only="-only-testing:WaddleUITests/DuoLayoutSweepTests"
    echo "== $1 at $2" >&2
    # With one test asked for, the shots the others took are kept.
    [ -n "$ONLY" ] || rm -rf "$raw"
    rm -rf "$OUT/results/$1-$2.xcresult"
    mkdir -p "$raw" "$OUT/results"
    rm -f "$request" "$request.staged" "$request.done" "$request.done.new"
    xcrun simctl ui "$3" content_size "$2"
    xcrun simctl uninstall "$3" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl install "$3" "$APP_PATH"
    provision "$3"
    serve "$1" "$3" "$raw" "$request" &
    HELPER_PID=$!
    # A red run is expected to be common here (one unreachable surface is a
    # failure) and must not cost the poses after it.
    TEST_RUNNER_WADDLE_DUO_SWEEP_REQUEST="$request" \
    TEST_RUNNER_WADDLE_DUO_SWEEP_POSE="$1" \
    xcodebuild test-without-building \
        -project App/Waddle.xcodeproj -scheme Waddle \
        -destination "platform=iOS Simulator,id=$3" \
        $only \
        -derivedDataPath "$DERIVED" -collect-test-diagnostics never \
        -resultBundlePath "$OUT/results/$1-$2.xcresult" -quiet >"$OUT/results/$1-$2.log" 2>&1 || status=$?
    stop_helper
    [ "$status" = 0 ] || echo "== xcodebuild exited $status for $1 at $2 (log: $OUT/results/$1-$2.log)" >&2
    finish "$1" "$2" "$raw" "$OUT/shots/$1/$2"
}

# Puts the simulator back the way a simulator boots, on EVERY way out of a
# run: the text size, and the pose. A run that stops in an opened pose (the
# hook failing after it pressed Open, the map sets never adopted, Ctrl-C)
# used to leave the device open and turned in Device Hub, because the only
# closing was the last line of a successful run and the trap asked devicectl
# for portrait, which changes nothing while Device Hub is running.
POSED=""
restore() {
    local status=$?
    trap - EXIT INT TERM
    stop_helper
    [ -n "$THE_UDID" ] || exit "$status"
    xcrun simctl ui "$THE_UDID" content_size large >/dev/null 2>&1 || true
    if [ -n "$POSED" ]; then
        if [ -n "$POSE_HOOK" ]; then
            "$POSE_HOOK" closed "$THE_UDID" "$NAME" >&2 \
                || echo "warning: could not close '$NAME' again; it may be left open or turned in Device Hub" >&2
        else
            xcrun devicectl device orientation set --device "$THE_UDID" portrait >/dev/null 2>&1 || true
        fi
    fi
    exit "$status"
}

run() {  # poses
    local pose size
    require_simulator
    [ -d "$APP_PATH" ] || { echo "error: no build at $APP_PATH; run '$0 prepare' first" >&2; exit 1; }
    mkdir -p "$OUT"
    xcrun swiftc -O Scripts/opaque-png.swift -o "$OUT/opaque-png"
    xcrun simctl boot "$THE_UDID" 2>/dev/null || true
    xcrun simctl bootstatus "$THE_UDID" >/dev/null
    trap restore EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for pose in "$@"; do
        # Set before the pose is asked for: a hook that fails half way has
        # already pressed something.
        POSED=1
        set_pose "$pose" "$THE_UDID"
        for size in $SIZES; do
            run_one "$pose" "$size" "$THE_UDID"
        done
    done
    echo "shots are in $OUT/shots; anything missing is listed in $OUT/problems.txt"
}

# One contact sheet per pose and size, every shot labelled, with ImageMagick.
sheets() {
    command -v montage >/dev/null || { echo "error: contact sheets need ImageMagick's montage (brew install imagemagick)" >&2; exit 1; }
    local dir pose size width columns
    mkdir -p "$OUT/sheets"
    for dir in "$OUT"/shots/*/*/; do
        [ -d "$dir" ] || continue
        size="$(basename "$dir")"; pose="$(basename "$(dirname "$dir")")"
        case "$(pose_window "$pose")" in wide) width=640; columns=4 ;; *) width=400; columns=6 ;; esac
        # `-label` before the files it labels; WebP because a sheet of dark
        # screens with small text is half the size of the same JPEG.
        montage -label '%t' "$dir"*.png -resize "${width}x" -geometry "+6+6" -tile "${columns}x" \
            -font /System/Library/Fonts/Supplemental/Arial.ttf -background '#202020' -fill white -pointsize 22 -strip -quality 60 "$OUT/sheets/$pose-$size.webp"
        echo "$OUT/sheets/$pose-$size.webp"
    done
}

case "${1:-}" in
    prepare)
        require_simulator
        udid="$THE_UDID"
        (cd App && xcodegen generate)
        xcodebuild build-for-testing -project App/Waddle.xcodeproj -scheme Waddle \
            -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$DERIVED" -quiet
        ;;
    run)
        shift
        [ $# -gt 0 ] || set -- $ALL_POSES
        for pose in "$@"; do
            case " $ALL_POSES " in *" $pose "*) ;; *) echo "unknown pose '$pose' ($ALL_POSES)" >&2; exit 2 ;; esac
        done
        run "$@"
        ;;
    finish)
        # Derives the upright shots again from the raw ones already taken.
        [ -x "$OUT/opaque-png" ] || xcrun swiftc -O Scripts/opaque-png.swift -o "$OUT/opaque-png"
        for dir in "$OUT"/raw/*/*/; do
            [ -d "$dir" ] || continue
            size="$(basename "$dir")"; pose="$(basename "$(dirname "$dir")")"
            finish "$pose" "$size" "${dir%/}" "$OUT/shots/$pose/$size"
        done
        ;;
    sheets) sheets ;;
    *) echo "usage: $0 prepare | run [pose ...] | finish | sheets" >&2; exit 2 ;;
esac
