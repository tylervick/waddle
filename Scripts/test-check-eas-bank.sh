#!/bin/bash
# Tests for Scripts/check-eas-bank.sh.
#
# Fully HERMETIC: every case builds a throwaway sonivox-shaped source tree in
# a temp dir and points the script at it with EAS_SRC. Nothing here reads the
# real Vendor/src/sonivox checkout or reaches the network.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/Scripts/check-eas-bank.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# A minimal tree carrying all seven arrays and a generated options header.
# Values are arbitrary but FIXED -- the point is that the script notices a
# change, not that these are the real instruments.
make_tree() { # dir
    local d="$1/arm-wt-22k/lib_src"
    mkdir -p "$d" "$1/build/libsonivox"
    cat > "$d/wt_22khz.c" <<'EOF'
static const S_ARTICULATION eas_articulations[] =
{
    { 32767, 30725, 0, 30725 },
};
static const S_WT_REGION eas_regions[] =
{
    { 0, 1, 2, 3 },
};
EOF
    cat > "$d/wt_200k_G.c" <<'EOF'
static const S_PROGRAM eas_programs[] =
{
    { 0, 1 },
};
static const S_BANK eas_banks[] =
{
    { 0, 0, 0 },
};
EOF
    cat > "$d/wt_200k_samples.c" <<'EOF'
static const EAS_SAMPLE eas_samples[0x10 + 20] =
{
    11, 12, 13, 14,
};
static const EAS_U32 eas_sampleLengths[] =
{
    0x04,
};
static const EAS_U32 eas_sampleOffsets[] =
{
    0x00,
};
EOF
    cat > "$1/build/libsonivox/eas_options.h" <<'EOF'
#define _8_BIT_SAMPLES
#define _SAMPLE_RATE_22050
#define NUM_OUTPUT_CHANNELS 2
EOF
}

run() { # dir
    env EAS_SRC="$1" \
        EAS_OPTIONS_H="$1/build/libsonivox/eas_options.h" \
        EAS_EXPECT_FILE="$TMP/expect.sh" "$SCRIPT"
}

make_tree "$TMP/baseline"
env EAS_SRC="$TMP/baseline" "$SCRIPT" --print > "$TMP/expect.sh"

# 1. A tree matching the recorded hashes passes. This is the baseline every
#    other case is measured against; if it fails, nothing below means anything.
make_tree "$TMP/ok"
out="$(run "$TMP/ok" 2>&1)" || fail "an unchanged bank was rejected: $out"
pass "unchanged bank passes"

# 2. A CHANGED instrument fails, and the message names WHICH array moved.
#    This is the case the guard exists for: a pin bump that alters what a
#    player hears must not read as routine upstream churn.
make_tree "$TMP/changed"
sed -i '' 's/11, 12, 13, 14,/11, 12, 13, 99,/' "$TMP/changed/arm-wt-22k/lib_src/wt_200k_samples.c"
if out="$(run "$TMP/changed" 2>&1)"; then
    fail "a changed sample table was accepted"
fi
echo "$out" | grep -q "eas_samples" \
    || fail "the failure did not name eas_samples; it said: $out"
pass "a changed instrument fails and names the array"

# 3. REORGANISED but unchanged still passes. This is the trap that motivated
#    the guard: upstream split one file into three, so a whole-file hash
#    reports a difference that does not exist. Moving an array between files
#    must not fail.
make_tree "$TMP/moved"
cat "$TMP/moved/arm-wt-22k/lib_src/wt_200k_G.c" >> "$TMP/moved/arm-wt-22k/lib_src/wt_22khz.c"
: > "$TMP/moved/arm-wt-22k/lib_src/wt_200k_G.c"
out="$(run "$TMP/moved" 2>&1)" || fail "a reorganised-but-unchanged bank was rejected: $out"
pass "reorganised-but-unchanged bank passes"

# 4. The arrays can be perfectly intact while the synth runs at the wrong
#    sample rate. A bank comparison that passes then proves nothing about
#    what anyone hears, so the options are asserted too.
make_tree "$TMP/rate"
cat > "$TMP/rate/build/libsonivox/eas_options.h" <<'EOF'
#define _8_BIT_SAMPLES
#define _SAMPLE_RATE_44100
#define NUM_OUTPUT_CHANNELS 2
EOF
if out="$(run "$TMP/rate" 2>&1)"; then
    fail "a 44100 Hz build was accepted"
fi
echo "$out" | grep -q "_SAMPLE_RATE_22050" \
    || fail "the failure did not name the expected sample-rate define; it said: $out"
pass "wrong sample rate fails"

# 5. Same, for sample width.
make_tree "$TMP/width"
cat > "$TMP/width/build/libsonivox/eas_options.h" <<'EOF'
#define _16_BIT_SAMPLES
#define _SAMPLE_RATE_22050
#define NUM_OUTPUT_CHANNELS 2
EOF
if out="$(run "$TMP/width" 2>&1)"; then
    fail "a 16-bit build was accepted"
fi
pass "wrong sample width fails"

# 6. No checkout is a SKIP, not a pass and not a failure -- someone running
#    the guards before `mise run build-deps` has not broken anything. The
#    skip must be distinguishable in the output so CI can re-fail on it where
#    the checkout is guaranteed to exist.
out="$(run "$TMP/absent" 2>&1)" || fail "a missing checkout was treated as a failure"
echo "$out" | grep -q '^skip - ' \
    || fail "a missing checkout did not print a skip line; it said: $out"
pass "missing checkout skips cleanly"

# 7. A checkout that EXISTS but is missing an array fails closed. This is a
#    broken or half-written tree, which is not the same as no tree at all,
#    and must never be quietly skipped.
make_tree "$TMP/partial"
: > "$TMP/partial/arm-wt-22k/lib_src/wt_200k_samples.c"
if out="$(run "$TMP/partial" 2>&1)"; then
    fail "a checkout missing eas_samples was accepted"
fi
echo "$out" | grep -q '^skip - ' && fail "a broken checkout was reported as a skip"
pass "a present-but-incomplete checkout fails closed"

# 8. Mono fails. The module reports AL_FORMAT_STEREO16 unconditionally, so a
#    mono build makes that report a lie. The symptom would be garbled audio,
#    not a build error, which is why it belongs in a guard.
make_tree "$TMP/mono"
cat > "$TMP/mono/build/libsonivox/eas_options.h" <<'EOF'
#define _8_BIT_SAMPLES
#define _SAMPLE_RATE_22050
#define NUM_OUTPUT_CHANNELS 1
EOF
if out="$(run "$TMP/mono" 2>&1)"; then
    fail "a mono build was accepted"
fi
echo "$out" | grep -q "STEREO16" \
    || fail "the failure did not explain the stereo assumption; it said: $out"
pass "mono build fails"

# 9. A checkout whose options header was never generated FAILS, and is not
#    reported as ok on the strength of the arrays alone. The arrays being
#    right says nothing about the rate, width or channel count the synth will
#    actually run at, and a guard that answers a question it did not ask is
#    worse than one that refuses.
make_tree "$TMP/noheader"
rm -f "$TMP/noheader/build/libsonivox/eas_options.h"
if out="$(run "$TMP/noheader" 2>&1)"; then
    fail "a checkout with no generated options header was accepted"
fi
echo "$out" | grep -q '^skip - ' && fail "a missing options header was reported as a skip"
pass "missing options header fails closed"

# 10. The extractor resolves each array to ITS OWN body, not to a neighbour's.
#     This case is not optional: the recorded expectations are produced by the
#     same script that checks them, so a loosely-anchored extractor is
#     self-consistent and every case above would still pass while the guard
#     silently compared eas_samples to itself three times.
#
#     In the real tree, eas_sampleLengths and eas_sampleOffsets sit below the
#     13,000-line eas_samples array in the same file, and a match on "name
#     appears on this line" resolves both of them to eas_samples. Distinct
#     arrays must therefore hash distinctly.
env EAS_SRC="$TMP/ok" "$SCRIPT" --print > "$TMP/print.sh"
n_lines="$(grep -c '^EXPECT_' "$TMP/print.sh")"
[ "$n_lines" = "7" ] || fail "--print emitted $n_lines expectations, expected 7"
n_unique="$(sed 's/.*="//;s/"$//' "$TMP/print.sh" | sort -u | wc -l | tr -d ' ')"
[ "$n_unique" = "7" ] \
    || fail "only $n_unique distinct hashes across 7 arrays -- the extractor is resolving different arrays to the same body"
pass "each array resolves to its own body"

# 11. A macro whose name merely STARTS with the expected one is not the
#     expected one. Anchoring only at the front accepts _SAMPLE_RATE_220500
#     and _8_BIT_SAMPLES_EXTRA, and a guard that accepts a macro it was not
#     looking for asserts nothing.
make_tree "$TMP/prefix"
cat > "$TMP/prefix/build/libsonivox/eas_options.h" <<'EOF'
#define _8_BIT_SAMPLES_EXTRA
#define _SAMPLE_RATE_220500
#define NUM_OUTPUT_CHANNELS 2
EOF
if out="$(run "$TMP/prefix" 2>&1)"; then
    fail "prefix-matched option macros were accepted"
fi
pass "prefix-matched option macros fail"

# 12. Both sample rates defined at once fails. Not reachable from today's
#     generator, which emits the unselected one as a comment -- stated now so
#     that if a later generator change makes it reachable, the positive checks
#     alone do not keep passing.
make_tree "$TMP/conflict"
cat > "$TMP/conflict/build/libsonivox/eas_options.h" <<'EOF'
#define _8_BIT_SAMPLES
#define _SAMPLE_RATE_22050
#define _SAMPLE_RATE_44100
#define NUM_OUTPUT_CHANNELS 2
EOF
if out="$(run "$TMP/conflict" 2>&1)"; then
    fail "conflicting sample-rate defines were accepted"
fi
pass "conflicting sample-rate defines fail"

# 13. Files that declare the SAME array names but are not in this build must be
#     ignored. Three files in the real tree declare eas_articulations and
#     friends -- wt_22khz.c (ours), plus hybrid_22khz_mcu.c and wt_44khz.c,
#     which are compiled only with EAS_HYBRID_SYNTH and USE_44KHZ, both off
#     here. hybrid_22khz_mcu.c sorts alphabetically BEFORE wt_22khz.c, so a
#     glob over lib_src/*.c silently reads the wrong bank and certifies
#     instruments the app never ships. That is not hypothetical: it is what
#     this guard did on its first run.
make_tree "$TMP/decoy"
cat > "$TMP/decoy/arm-wt-22k/lib_src/hybrid_22khz_mcu.c" <<'EOF'
static const S_ARTICULATION eas_articulations[] =
{
    { 1, 1, 1, 1 },
};
static const S_WT_REGION eas_regions[] =
{
    { 9, 9, 9, 9 },
};
static const S_PROGRAM eas_programs[] =
{
    { 7, 7 },
};
static const S_BANK eas_banks[] =
{
    { 7, 7, 7 },
};
static const EAS_SAMPLE eas_samples[0x10 + 20] =
{
    99, 99, 99, 99,
};
EOF
cat > "$TMP/decoy/arm-wt-22k/lib_src/wt_44khz.c" <<'EOF'
static const S_ARTICULATION eas_articulations[] =
{
    { 2, 2, 2, 2 },
};
EOF
out="$(run "$TMP/decoy" 2>&1)"     || fail "a decoy bank in a file this build does not compile changed the verdict: $out"
pass "arrays in files outside this build configuration are ignored"

echo "All check-eas-bank tests passed."
