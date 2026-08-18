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

run() { env EAS_PROBE_BIN="$1" "$SCRIPT"; }

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

echo "All check-eas-realtime tests passed."
