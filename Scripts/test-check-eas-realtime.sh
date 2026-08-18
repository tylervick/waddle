#!/bin/bash
# Tests for Scripts/check-eas-realtime.sh.
#
# Fully HERMETIC: the probe is stubbed with a script that prints a chosen rtf
# line, so no compiler runs, no audio is synthesised, and the suite is
# instant. What is under test is the threshold decision and the skip/fail
# split -- not EAS itself.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/Scripts/check-eas-realtime.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# A stub standing in for the compiled probe. Strict: anything it does not
# expect is a loud failure rather than a quiet pass.
make_probe() { # path rtf-line
    cat > "$1" <<EOF
#!/bin/bash
if [ \$# -lt 1 ]; then echo "stub probe: no midi argument" >&2; exit 64; fi
echo "$2"
EOF
    chmod +x "$1"
}

# The threshold is passed EXPLICITLY, never inherited. A developer with
# EAS_MIN_RTF set in their shell would otherwise have every "default" case
# silently test a different floor, and the suite would pass or fail depending on
# whose machine it ran on.
run() { # probe [min_rtf]
    env EAS_PROBE_BIN="$1" EAS_MIN_RTF="${2:-5}" "$SCRIPT"
}

# 1. Comfortably ahead of playback passes. 24x is the conservative on-device
#    figure the design projects from a 1229x dev-machine measurement.
make_probe "$TMP/fast" "frames=114432 seconds=5.190 wall=0.2163 rtf=24.0"
out="$(run "$TMP/fast" 2>&1)" || fail "a 24x real-time factor was rejected: $out"
echo "$out" | grep -q "24.0" || fail "the pass did not report the measured factor: $out"
pass "comfortably-ahead synthesis passes"

# 2. Below the floor fails. A synth that cannot stay 5x ahead of playback will
#    stutter on a device under load even though it 'works' on a desk.
make_probe "$TMP/slow" "frames=114432 seconds=5.190 wall=1.7300 rtf=3.0"
if out="$(run "$TMP/slow" 2>&1)"; then
    fail "a 3x real-time factor was accepted"
fi
echo "$out" | grep -q "3.0" || fail "the failure did not report the measured factor: $out"
pass "below-floor synthesis fails"

# 3. Slower than playback fails. Stated separately from case 2 because this is
#    the outright-broken shape, and a threshold that only catches it is not
#    the guard this repo asked for.
make_probe "$TMP/broken" "frames=114432 seconds=5.190 wall=8.0000 rtf=0.6"
if run "$TMP/broken" >/dev/null 2>&1; then
    fail "synthesis slower than playback was accepted"
fi
pass "slower-than-playback fails"

# 4. A probe that cannot be built or run is a SKIP, not a pass. Someone
#    running the guards without having built the dependency has broken
#    nothing, and CI re-fails on the skip where the dependency is guaranteed.
out="$(run "$TMP/nonexistent-probe" 2>&1)" || fail "an unbuildable probe was treated as a failure"
echo "$out" | grep -q '^skip - ' || fail "an unbuildable probe did not print a skip: $out"
pass "unbuildable probe skips cleanly"

# 5. A probe that RUNS but emits no rtf field fails closed. That is a broken
#    probe, not an absent one, and reading a missing number as 'fine' is the
#    fail-open shape docs/learnings/masked-exit-status-fails-open.md is about.
make_probe "$TMP/garbage" "frames=0 seconds=0.000 wall=0.0001"
if out="$(run "$TMP/garbage" 2>&1)"; then
    fail "a probe emitting no rtf was accepted"
fi
echo "$out" | grep -q '^skip - ' && fail "a broken probe was reported as a skip"
pass "probe with no rtf fails closed"

# 6. A malformed factor fails rather than passing. `[0-9.]*` matches "1.2.3",
#    on which bc errors and prints nothing -- and comparing "" against "1" is
#    false, so the old code fell through to `ok`. A guard that reports success
#    on a measurement it could not read is worse than no guard.
make_probe "$TMP/malformed" "frames=114432 seconds=5.190 wall=0.2163 rtf=1.2.3"
if out="$(run "$TMP/malformed" 2>&1)"; then
    fail "a malformed real-time factor was accepted"
fi
echo "$out" | grep -q "malformed" \
    || fail "the failure did not name the malformed value; it said: $out"
pass "malformed real-time factor fails closed"

# 7. Same for the floor. An EAS_MIN_RTF typo must be a loud refusal, not a
#    comparison that silently never fires.
make_probe "$TMP/goodrtf" "frames=114432 seconds=5.190 wall=0.2163 rtf=24.0"
if out="$(run "$TMP/goodrtf" five 2>&1)"; then
    fail "a non-numeric EAS_MIN_RTF was accepted"
fi
pass "non-numeric floor fails closed"

# 8. A factor with a trailing suffix fails. Capturing only the numeric prefix
#    would read "24.0ms" as "24.0" and validate THAT -- inspecting a value the
#    probe never reported, which is validation theatre rather than validation.
make_probe "$TMP/suffix" "frames=114432 seconds=5.190 wall=0.2163 rtf=24.0ms"
if out="$(run "$TMP/suffix" 2>&1)"; then
    fail "a real-time factor with a trailing suffix was accepted"
fi
echo "$out" | grep -q "malformed" \
    || fail "the failure did not name the malformed value; it said: $out"
pass "suffixed real-time factor fails closed"

# 9. The threshold under test is the one this suite passes, never one
#    inherited from the environment. Proven by setting a hostile value in the
#    caller's environment and confirming the default cases still use 5:
#    at EAS_MIN_RTF=100000 a 24x probe would fail if the value leaked through.
export EAS_MIN_RTF=100000
out="$(run "$TMP/fast" 2>&1)" \
    || fail "an inherited EAS_MIN_RTF leaked into the default cases: $out"
unset EAS_MIN_RTF
pass "the threshold is pinned by the suite, not inherited"

echo "All check-eas-realtime tests passed."
