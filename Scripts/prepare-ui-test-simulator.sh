#!/bin/bash
# Boots the UI-test simulator and waits until its lock-screen wallpaper gallery
# has been rendered, so that work is over before the first test launches the
# app instead of landing on a launch.
#
# Issues #386 and #396. On a fresh runner the simulator's PosterBoard renders a
# snapshot of every lock-screen wallpaper once: 184 to 368 renders, 100 to 210 s
# of a busy runner. WHEN it does that is decided by the host's uptime at the
# moment the gallery arrives, about two minutes after the simulator boots. Its
# own log says so:
#
#   past the window:   Gallery controller requested snapshot prewarm for role:
#                      PRPosterRoleLockScreen (reason: ...)
#                      ... Successfully prewarmed gallery snapshots for role: ...
#   inside the window: Gallery controller requested snapshot prewarm for role
#                      PRPosterRoleLockScreen, but prewarm has not run and uptime
#                      392s is within 600s boot window; deferring to -prewarm:
#
# Deferred, the renders run in a "prewarm" 5 to 20 minutes later, in the middle
# of the tests; every #396 failure examined (3 of 3) is that prewarm, with the
# launch it landed on reported 75 to 86 s late. Not deferred, they ran while the
# first test was launching the app in three of the four #386 failures examined.
# See docs/learnings/ui-test-launch-flakes-and-the-wallpaper-gallery.md.
#
# So this script waits for a CONDITION, twice, and never for luck:
#   1. the host has been up for the boot window, so the gallery cannot be
#      deferred into the test session;
#   2. after booting, the simulator's log carries the "Successfully prewarmed
#      gallery snapshots" line.
#
# Exit status. 0 with a WADDLE_SIMULATOR_SETTLED line when both held. Also 0,
# with a WADDLE_SIMULATOR_NOT_SETTLED warning naming the reason, when the
# renders were deferred anyway or the line never came: the tests then run as
# they did before this script existed, and the marker is what tells a run that
# waited from one that was merely lucky. Non-zero only when the simulator
# cannot be found or booted, or the host's boot time cannot be read; those are
# not states to run a test session in.
#
# Knobs, for the test suite and for a runtime whose numbers move:
#   SIMULATOR_READY_BOOT_WINDOW  seconds of host uptime to wait for (600)
#   SIMULATOR_READY_TIMEOUT      seconds to wait for the renders (900)
#   SIMULATOR_READY_POLL         seconds between looks at the log (10)
#
# Usage: Scripts/prepare-ui-test-simulator.sh <device-name> <os-version>
# Prints `udid=<UDID>` to $GITHUB_OUTPUT when that is set.
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 <device-name> <os-version>" >&2
    exit 2
fi
DEVICE_NAME="$1"
OS_VERSION="$2"

BOOT_WINDOW="${SIMULATOR_READY_BOOT_WINDOW:-600}"
TIMEOUT="${SIMULATOR_READY_TIMEOUT:-900}"
POLL="${SIMULATOR_READY_POLL:-10}"

say() { echo "[$(date -u '+%H:%M:%S')] $*"; }

# --- which device -----------------------------------------------------------
# Same right-to-left parse as check-simulator-available.sh, for the reason in
# docs/learnings/simctl-device-names-contain-parens.md. That guard has already
# run and retried by the time this is called, so one query is enough here.
if ! listing="$(xcrun simctl list devices available 2>&1)"; then
    echo "::error::simctl could not list devices: $listing"
    exit 1
fi
UDID="$(printf '%s\n' "$listing" | awk -v os="$OS_VERSION" -v dev="$DEVICE_NAME" '
    /^-- / { insection = ($0 == "-- iOS " os " --"); next }
    insection && /^    / {
        line = $0
        sub(/^    /, "", line)
        sub(/[[:space:]]+$/, "", line)
        sub(/ \([^()]*\)$/, "", line)
        n = match(line, / \([^()]*\)$/)
        if (n == 0) next
        name = substr(line, 1, n - 1)
        udid = substr(line, n + 2, RLENGTH - 3)
        if (name == dev && found == "") found = udid
    }
    END { print found }
')"
if [ -z "$UDID" ]; then
    echo "::error::no available simulator named '$DEVICE_NAME' on iOS $OS_VERSION"
    exit 1
fi
say "device: $DEVICE_NAME (iOS $OS_VERSION) $UDID"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "udid=$UDID" >> "$GITHUB_OUTPUT"
fi

# --- condition 1: the host is past PosterBoard's boot window ------------------
# kern.boottime prints "{ sec = 1763600000, usec = 0 } Fri Nov 20 ...". This is
# the clock PosterBoard reads: the simulator shares the host's kernel, and the
# uptime in its deferral line is the runner's, not the simulator's.
if ! boottime="$(sysctl -n kern.boottime 2>&1)"; then
    echo "::error::could not read kern.boottime: $boottime"
    exit 1
fi
boot_sec="$(printf '%s\n' "$boottime" | sed -n 's/^{ sec = \([0-9][0-9]*\),.*/\1/p')"
if [ -z "$boot_sec" ]; then
    echo "::error::could not parse kern.boottime: $boottime"
    exit 1
fi
uptime_s=$(( $(date +%s) - boot_sec ))
if [ "$uptime_s" -lt "$BOOT_WINDOW" ]; then
    wait_s=$(( BOOT_WINDOW - uptime_s ))
    say "host uptime ${uptime_s}s is inside the ${BOOT_WINDOW}s boot window; waiting ${wait_s}s before booting"
    sleep "$wait_s"
else
    wait_s=0
    say "host uptime ${uptime_s}s is past the ${BOOT_WINDOW}s boot window; booting now"
fi

# --- boot ---------------------------------------------------------------------
# `bootstatus -b` boots a shut-down device and returns once it has finished
# booting; on a booted one it returns at once. --start below is local time,
# which is what `log show` both prints and parses.
log_start="$(date '+%Y-%m-%d %H:%M:%S')"
if ! xcrun simctl bootstatus "$UDID" -b; then
    echo "::error::simulator $UDID did not boot"
    exit 1
fi
say "boot finished"

# --- condition 2: the gallery snapshots have been rendered --------------------
PREDICATE='process == "PosterBoard" AND (eventMessage CONTAINS "requested snapshot prewarm" OR eventMessage CONTAINS "Calling prewarmSnapshotsForRequests" OR eventMessage CONTAINS "Successfully prewarmed gallery snapshots")'
polls=$(( TIMEOUT / POLL ))
if [ "$polls" -lt 1 ]; then polls=1; fi
outcome="timeout"
deferral=""
announced=""
query_failures=0
i=0
while [ "$i" -lt "$polls" ]; do
    i=$(( i + 1 ))
    # A failed query is not an answer: count it and look again. Reading its
    # empty output as "nothing logged yet" is right for one poll and wrong as a
    # verdict, so the count is reported if the wait runs out.
    if lines="$(xcrun simctl spawn "$UDID" log show --start "$log_start" --style compact --predicate "$PREDICATE" 2>/dev/null)"; then
        case "$lines" in
            *"deferring to -prewarm"*)
                outcome="deferred"
                deferral="$(printf '%s\n' "$lines" | grep -F 'deferring to -prewarm' | tail -1)"
                break ;;
        esac
        case "$lines" in
            *"Successfully prewarmed gallery snapshots"*)
                outcome="settled"
                break ;;
        esac
        case "$lines" in
            *"Calling prewarmSnapshotsForRequests"*)
                if [ -z "$announced" ]; then
                    announced=1
                    say "PosterBoard is rendering the gallery ($(printf '%s\n' "$lines" | grep -F 'Calling prewarmSnapshotsForRequests' | tail -1 | sed 's/.*Calling prewarmSnapshotsForRequests with //'))"
                fi ;;
        esac
    else
        query_failures=$(( query_failures + 1 ))
    fi
    sleep "$POLL"
done
waited=$(( (i - 1) * POLL ))

if ! load="$(sysctl -n vm.loadavg 2>/dev/null)"; then load="unknown"; fi
case "$outcome" in
    settled)
        say "WADDLE_SIMULATOR_SETTLED gallery snapshots rendered about ${waited}s after boot (waited ${wait_s}s for the boot window first; load $load)" ;;
    deferred)
        echo "::warning::WADDLE_SIMULATOR_NOT_SETTLED reason=deferred -- PosterBoard put the gallery renders off to its prewarm although the host was past the boot window; they will run during the tests (issue 396). Its line: $deferral" ;;
    *)
        echo "::warning::WADDLE_SIMULATOR_NOT_SETTLED reason=timeout -- no gallery-render line in the simulator log ${waited}s after boot ($query_failures of $i log queries failed). The tests run anyway; if a launch fails, read it as issues 386/396." ;;
esac
exit 0
