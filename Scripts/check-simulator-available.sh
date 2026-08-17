#!/bin/bash
# Confirms a named iOS Simulator device/OS pair is genuinely available before
# a build spends the whole run against it.
#
# CI run 31427755601 on PR #66 failed with "Unable to find a device matching
# the provided destination specifier: { platform:iOS Simulator, OS:26.2,
# name:iPhone 17 Pro }". The identical commit, on the identical runner image
# (macos-26-arm64/20260728.0273), had passed two days earlier, and a bare
# re-run with no code change passed. The tell: xcodebuild's own "Available
# destinations" list had NO simulators at all -- only `My Mac` and two
# `dvtdevice-...placeholder` entries -- and it failed ~60s in. A genuinely
# wrong destination pin still lists the runner's other simulators; an empty
# list means CoreSimulator never enumerated anything. See
# docs/learnings/simulator-enumeration-race.md.
#
# This guard queries `xcrun simctl list devices available` itself, ahead of
# the real xcodebuild invocation, and distinguishes the two failure shapes
# because they call for different responses:
#   - ZERO devices enumerated, for ANY runtime: CoreSimulator itself failed
#     to enumerate on this runner. Infrastructure, not the code under test.
#     Exits with the WADDLE_SIMULATOR_UNAVAILABLE marker so a log grep --
#     including Scripts/loop-prompt.md section 4 -- can tell this apart from
#     a real regression and just re-run the job.
#   - Devices enumerated, but none match the requested name/OS: a genuine
#     destination pin problem. A re-run will not fix this, so the marker is
#     NOT printed.
#
# Retries on a bounded schedule before giving up, because the failure above
# is a race on a cold runner, not a permanent state -- judging the first
# query alone would just relocate the flake into this script's exit code.
# Override SIMULATOR_CHECK_ATTEMPTS / SIMULATOR_CHECK_DELAY (seconds) to
# change the schedule; the test suite sets the delay to 0 to stay fast.
#
# Usage: Scripts/check-simulator-available.sh <device-name> <os-version>
#   e.g.  Scripts/check-simulator-available.sh "iPhone 17 Pro" 26.2
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 <device-name> <os-version>" >&2
    exit 2
fi
DEVICE_NAME="$1"
OS_VERSION="$2"

ATTEMPTS="${SIMULATOR_CHECK_ATTEMPTS:-5}"
DELAY="${SIMULATOR_CHECK_DELAY:-15}"

# Set by query_once on every attempt and read after the loop ends, so the
# final classification and diagnostic dump always reflect the LAST attempt
# made, whether it matched or not. bash 3.2 has no clean way to return
# several values from a function, and these are read at a single call site
# immediately after each call, so globals are no less clear here.
listing=""
total_count=0
match_line=""

query_once() {
    # Do not mask this command's exit status: a failure of simctl itself
    # (CoreSimulatorService unreachable, timed out, etc.) is exactly the
    # same infrastructure signal as a successful call that enumerates zero
    # devices, and must land in that same bucket -- not be silently read as
    # an empty-but-successful result. See
    # docs/learnings/masked-exit-status-fails-open.md.
    if listing="$(xcrun simctl list devices available 2>&1)"; then
        : # fall through; $listing holds real output to parse below
    else
        listing=""
    fi

    # Device lines are indented four spaces under a "-- <runtime> --"
    # header; the "== Devices ==" banner and the headers themselves are not
    # indented. This counts every enumerated device across every runtime,
    # not just the requested one -- the incident's tell was an empty list
    # across the board, not merely for one OS.
    total_count="$(printf '%s\n' "$listing" | grep -cE '^    [^[:space:]]' || true)"

    # Exact-match the device name against the section for the requested OS.
    # A substring match would let "iPhone 17" match "iPhone 17 Pro".
    #
    # The name is recovered by peeling the two trailing parenthesised fields
    # -- "(<udid>) (<state>)" -- off the RIGHT end of the line. This used to
    # cut at the first " (" instead, which is correct only for devices whose
    # own name has no parentheses: every iPad has them ("iPad Pro 13-inch
    # (M4)", "iPad (A16)"), so the guard read that name as "iPad Pro
    # 13-inch", found no match, and reported a present device as a bad
    # destination pin. See docs/learnings/simctl-device-names-contain-parens.md.
    match_line="$(printf '%s\n' "$listing" | awk -v os="$OS_VERSION" -v dev="$DEVICE_NAME" '
        /^-- / { insection = ($0 == "-- iOS " os " --"); next }
        insection && /^    / {
            line = $0
            sub(/^    /, "", line)
            sub(/[[:space:]]+$/, "", line)
            name = line
            sub(/ \([^()]*\)$/, "", name)
            sub(/ \([^()]*\)$/, "", name)
            if (name == dev) { print line; exit }
        }
    ')"
}

attempt=1
while [ "$attempt" -le "$ATTEMPTS" ]; do
    query_once
    if [ -n "$match_line" ]; then
        echo "matched: $match_line (iOS $OS_VERSION, attempt $attempt/$ATTEMPTS)"
        exit 0
    fi
    if [ "$attempt" -lt "$ATTEMPTS" ]; then
        sleep "$DELAY"
    fi
    attempt=$((attempt + 1))
done

if [ "$total_count" -eq 0 ]; then
    echo "::error::WADDLE_SIMULATOR_UNAVAILABLE -- CoreSimulator enumerated zero simulators (any OS, any device) after $ATTEMPTS attempts. This is runner infrastructure, not the code under test -- re-run the job; do not attempt a code fix."
else
    echo "::error::requested simulator not found: '$DEVICE_NAME' (iOS $OS_VERSION) -- $total_count other device(s) enumerated, none matching. This is a genuine destination pin problem; re-running the job will not fix it."
fi
echo "requested: name=\"$DEVICE_NAME\" OS=$OS_VERSION"
echo "xcrun simctl list devices available (last attempt):"
printf '%s\n' "$listing"
exit 1
