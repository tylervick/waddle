#!/bin/bash
# Refuses a MIDI synthesis path that cannot stay comfortably ahead of playback
# (#116). Wavetable synthesis is sustained CPU work where OPL3 emulation was
# cheap, and nothing else in this repo would notice it getting slower.
#
# The threshold is a RATIO with large headroom, deliberately. Absolute
# millisecond budgets on hosted runners are noise, and a flaky performance gate
# gets ignored, which is worse than no gate. 5x survives runner jitter while
# still catching the regression that matters: synthesis that stops keeping up.
# Do not tighten it toward whatever was last measured.
#
# skip  - the probe could not be built or found (dependency not built yet).
# error - the probe ran and reported a factor below the floor, or reported no
#         factor at all.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

MIN_RTF="${EAS_MIN_RTF:-5}"
MIDI="${EAS_MIDI_FIXTURE:-$ROOT/Scripts/fixtures/eas-realtime.mid}"
PROBE="${EAS_PROBE_BIN:-}"

err() { echo "error: $*" >&2; exit 1; }

# Build the probe unless the caller supplied one (the suite does).
if [ -z "$PROBE" ]; then
    SRC="$ROOT/Vendor/src/sonivox"
    BUILD="$ROOT/Vendor/build/sonivox-host"
    if [ ! -d "$SRC" ]; then
        echo "skip - no sonivox checkout at $SRC (run: mise run build-deps)"
        exit 0
    fi
    # A host build, because the iOS library cannot run here. Same synth options
    # as Scripts/build-deps.sh, so the thing measured is the thing shipped.
    if ! cmake -S "$SRC" -B "$BUILD" -G Ninja \
            -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
            -DUSE_44KHZ=OFF -DUSE_16BITS_SAMPLES=OFF -DNEW_HOST_WRAPPER=ON \
            -DSF2_SUPPORT=OFF -DZLIB_SUPPORT=OFF \
            -DEAS_WT_SYNTH=ON -DEAS_FM_SYNTH=OFF \
            -DBUILD_TESTING=OFF -DBUILD_APPLICATION=OFF >/dev/null; then
        echo "skip - could not configure a host sonivox build"
        exit 0
    fi
    if ! cmake --build "$BUILD" >/dev/null; then
        echo "skip - could not build host sonivox"
        exit 0
    fi
    PROBE="$BUILD/eas-realtime-probe"
    if ! cc -O2 -o "$PROBE" "$ROOT/Scripts/eas-realtime-probe.c" \
            -I"$SRC/arm-wt-22k/host_src" -I"$SRC/arm-wt-22k/lib_src" \
            -I"$BUILD/libsonivox" "$BUILD/libsonivox.a"; then
        echo "skip - could not compile the real-time probe"
        exit 0
    fi
fi

if [ ! -x "$PROBE" ]; then
    echo "skip - no real-time probe at $PROBE"
    exit 0
fi

# Test the STATUS, then interpret the output -- never `|| true` on a command
# whose output decides something. See
# docs/learnings/masked-exit-status-fails-open.md.
if ! out="$("$PROBE" "$MIDI" 2>&1)"; then
    err "the real-time probe failed: $out"
fi

# Capture the whole non-whitespace token, NOT just its numeric prefix.
# `\([0-9.]*\)` would read "rtf=24.0ms" as "24.0", which then sails through
# is_decimal below -- the validation would be inspecting a value the probe
# never reported.
rtf="$(echo "$out" | sed -n 's/.*rtf=\([^[:space:]]*\).*/\1/p')"
[ -n "$rtf" ] || err "the probe produced no real-time factor: $out"

# Both operands must be well-formed decimals BEFORE bc sees them. `[0-9.]*`
# happily matches "1.2.3", on which bc errors, prints nothing, and the old
# `[ "" = "1" ]` test was false -- so a malformed measurement reported ok.
# That is the fail-open shape this guard exists to avoid, in the guard itself.
is_decimal() { # value
    printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)?$'
}
is_decimal "$rtf" \
    || err "the probe reported a malformed real-time factor '$rtf' -- refusing to guess. Full output: $out"
is_decimal "$MIN_RTF" \
    || err "EAS_MIN_RTF is '$MIN_RTF', which is not a decimal number"

# Test the STATUS of bc separately from its output: a missing bc, or one that
# errors, must not read as "not below the floor".
if ! below="$(echo "$rtf < $MIN_RTF" | bc -l 2>/dev/null)"; then
    err "could not compare ${rtf} against the ${MIN_RTF}x floor -- is bc available?"
fi
case "$below" in
    0|1) ;;
    *)   err "comparing ${rtf} against ${MIN_RTF} produced '$below' rather than 0 or 1" ;;
esac

if [ "$below" = "1" ]; then
    err "MIDI synthesis real-time factor is ${rtf}x, below the ${MIN_RTF}x floor. Music will stutter on device before it does here."
fi

echo "ok - MIDI synthesis runs ${rtf}x faster than playback (floor ${MIN_RTF}x)"
