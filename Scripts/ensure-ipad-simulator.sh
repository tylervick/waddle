#!/bin/bash
# Guarantees the iPad simulator this repo tests and photographs on exists,
# and prints its UDID.
#
# WHY THIS IS NOT JUST A DESTINATION STRING: the 13" iPad is created on
# demand, not pre-provisioned. `iPad Pro 13-inch (M4)` is the REQUIRED App
# Store 13" size class and the largest layout the app ships into; the iPad
# that a machine or a CI runner image does hand you is `iPad (A16)`, which is
# 11" class and lays out differently. Substituting it silently tests the wrong
# size class, so the device TYPE below is the load-bearing value here -- the
# name alone would happily match the wrong hardware if someone renamed a
# device, and picking "any iPad" would pick the wrong one.
#
# This file is the single owner of that type id. Scripts/capture-screenshots.sh
# used to carry its own copy alongside its own `simctl create`; both callers
# now come here, so the two cannot drift into testing one size class and
# shipping screenshots of another.
#
# ORDERING, in CI: run Scripts/check-simulator-available.sh for the *phone*
# first. CoreSimulator can enumerate zero devices on a cold runner (see
# docs/learnings/simulator-enumeration-race.md), and this script reads that
# same enumeration -- during such a window it would see no iPad and create a
# duplicate. The phone check retries until enumeration is healthy, so passing
# it first is what makes the lookup below trustworthy.
#
# Usage:
#   Scripts/ensure-ipad-simulator.sh [os-version]   # ensure; prints the UDID
#   Scripts/ensure-ipad-simulator.sh --name         # print the device name
#
# With no os-version, the newest installed iOS runtime is used -- what a
# developer wants locally. CI passes its pinned SIMULATOR_OS explicitly and
# then re-checks with Scripts/check-simulator-available.sh, so a device
# created under the wrong runtime fails loudly there rather than testing on
# an OS nobody pinned.
#
# The UDID is the ONLY thing written to stdout, so a caller can substitute it
# directly; progress and diagnostics go to stderr.
set -euo pipefail

# The device this repo tests on, and the CoreSimulator type that produces it.
IPAD_NAME="iPad Pro 13-inch (M4)"
IPAD_DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB"

if [ "${1:-}" = "--name" ]; then
    # Deliberately before any simctl call: callers that only need the name
    # (Scripts/capture-screenshots.sh reads it to build its output slug) must
    # not pay for, or be able to fail on, a CoreSimulator query.
    printf '%s\n' "$IPAD_NAME"
    exit 0
fi

if [ $# -gt 1 ]; then
    echo "usage: $0 [os-version | --name]" >&2
    exit 2
fi

# Newest installed iOS runtime, by version rather than by listing order or by
# identifier text: `iOS-9-3` sorts after `iOS-18-3` lexically, so the sort has
# to be numeric per component.
newest_ios_version() {
    local listing
    if listing="$(xcrun simctl list runtimes available 2>&1)"; then
        :
    else
        echo "error: 'xcrun simctl list runtimes available' failed:" >&2
        printf '%s\n' "$listing" >&2
        return 1
    fi
    printf '%s\n' "$listing" \
        | awk '/^iOS /{print $2}' \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -1
}

if [ $# -eq 1 ]; then
    OS_VERSION="$1"
else
    OS_VERSION="$(newest_ios_version)" \
        || { echo "error: could not enumerate iOS runtimes" >&2; exit 1; }
    if [ -z "$OS_VERSION" ]; then
        echo "error: no iOS simulator runtime is installed" >&2
        exit 1
    fi
    echo "no OS given; using the newest installed iOS runtime: $OS_VERSION" >&2
fi

# UDID of an available device with exactly this name under exactly this
# runtime, or empty. Exact-match on the name for the same reason
# check-simulator-available.sh does it: a substring match would accept
# "iPad Pro 13-inch (M4) spare", a device with unknown state.
#
# Do not mask the query's exit status -- a failure of simctl itself is not the
# same signal as a successful query that found nothing, and folding them
# together would have this script create a second device every time
# CoreSimulator hiccuped. See docs/learnings/masked-exit-status-fails-open.md.
find_udid() {
    local listing
    if listing="$(xcrun simctl list devices available 2>&1)"; then
        :
    else
        echo "error: 'xcrun simctl list devices available' failed:" >&2
        printf '%s\n' "$listing" >&2
        return 1
    fi
    # awk selects the line, sed extracts the UDID from it -- not one awk with
    # a `{36}` interval, which the awk macOS ships (BWK awk) does not support
    # and silently fails to match. `sed -n ... p` prints nothing when the line
    # carries no UDID, rather than echoing the line back unchanged.
    printf '%s\n' "$listing" | awk -v os="$OS_VERSION" -v dev="$IPAD_NAME" '
        /^-- / { insection = ($0 == "-- iOS " os " --"); next }
        insection && /^    / {
            line = $0
            sub(/^    /, "", line)
            sub(/[[:space:]]+$/, "", line)
            # Peel the two trailing parenthesised fields -- "(<udid>) (<state>)"
            # -- from the RIGHT. Cutting at the first " (" instead would
            # truncate every device whose own name is parenthesised, which is
            # every iPad this repo cares about: "iPad Pro 13-inch (M4)" would
            # be read as "iPad Pro 13-inch" and never match.
            name = line
            sub(/ \([^()]*\)$/, "", name)
            sub(/ \([^()]*\)$/, "", name)
            if (name == dev) { print line; exit }
        }' | sed -n -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/p'
}

udid="$(find_udid)" || { echo "error: could not enumerate simulators" >&2; exit 1; }

if [ -n "$udid" ]; then
    echo "already present: $IPAD_NAME (iOS $OS_VERSION) $udid" >&2
    printf '%s\n' "$udid"
    exit 0
fi

RUNTIME_ID="com.apple.CoreSimulator.SimRuntime.iOS-$(printf '%s' "$OS_VERSION" | tr '.' '-')"
echo "creating $IPAD_NAME (iOS $OS_VERSION) from $IPAD_DEVICE_TYPE" >&2
udid="$(xcrun simctl create "$IPAD_NAME" "$IPAD_DEVICE_TYPE" "$RUNTIME_ID")"

# `simctl create` exiting 0 with nothing on stdout would otherwise hand the
# caller an empty destination id, which xcodebuild reports as a confusing
# "Unable to find a device matching the provided destination specifier".
if [ -z "$udid" ]; then
    echo "error: 'xcrun simctl create' succeeded but printed no UDID" >&2
    exit 1
fi

echo "created: $udid" >&2
printf '%s\n' "$udid"
