#!/bin/bash
# Refuses a sonivox pin whose instrument bank changed, or whose sample rate or
# sample width moved off the values that reproduce the predecessor apps' sound
# (#116).
#
# Why this is not a file hash: upstream split the 1.39 MB wt_22khz.c into three
# files. A whole-file comparison against the predecessor's copy reports a
# mismatch that is not one -- the bank was reorganised, not changed. This
# extracts the seven arrays by declaration line instead, so moving one between files is
# invisible and altering one value is not.
#
# skip  - the sonivox checkout is absent (nobody has run `mise run build-deps`).
# error - the checkout is present but an array is missing, an array changed, or
#         the generated options do not select 22 kHz 8-bit. All fail closed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SRC="${EAS_SRC:-$ROOT/Vendor/src/sonivox}"
# The INSTALLED header, which is the one the engine actually compiles against
# (it is in sonivox's PUBLIC_HEADERS). The copy under Vendor/build is generated
# too, but checking the build tree would let a stale build satisfy a guard about
# what shipped.
#
# Note the directory: install puts these under include/sonivox/, while the
# build tree generates them under libsonivox/. Measured 2026-08-18 -- the
# libsonivox/ prefix is the build layout only, and a guard pointed there
# finds nothing.
OPTS="${EAS_OPTIONS_H:-$ROOT/Vendor/out/iphoneos/include/sonivox/eas_options.h}"

# Recorded hashes. Regenerate with:  Scripts/check-eas-bank.sh --print
# Do NOT copy these from the design doc -- that measured a different
# normalisation, and a hash that was never produced by this script cannot
# match one that is.
EXPECT_eas_articulations="79e20d658208482bf16a2acdffd9a1d06097ade02e006480b134314b498377be"
EXPECT_eas_regions="507ef37ee0a94dae7f5b38e271f0fa6410c3e82a79fddd3d291ef06418fbe96e"
EXPECT_eas_programs="d6aa7433e654794bb38b9fc531a3914f9e2ff812c786ffcc91331941457ed6f9"
EXPECT_eas_banks="32dc9be4519119c96735db020d14f77b3969728248b7e264eeb88de32ecf91a0"
EXPECT_eas_samples="1eabf149a7f03d899d1445cdab406d47e9828ea859f9dce96e3e9c6649a3f38c"
EXPECT_eas_sampleLengths="9c9f34ef41bb532cee1b3fc0b813a6b139b0bcd49a9fdd6266e9ef63040a417a"
EXPECT_eas_sampleOffsets="3cf5d1116033dbfb32cb7e76a33869010fef8aaccea2915c6a52e43ae3e04e43"

# The suite supplies its own expectations for its fixture trees. Unset in
# normal use, so the recorded values above are what CI enforces.
if [ -n "${EAS_EXPECT_FILE:-}" ]; then
    # shellcheck disable=SC1090
    . "$EAS_EXPECT_FILE"
fi

err() { echo "error: $*" >&2; exit 1; }

# Body of a named array, from its declaration to the closing brace, with
# whitespace and trailing comments removed so formatting churn is invisible.
# Searches every lib_src file, so an array that moves between files still
# resolves -- that is the entire point.
#
# The anchor is the DECLARATION line -- `[static] const <type> <name>[` -- not
# merely a line containing the name. Anchoring loosely is not a style
# preference: `eas_sampleLengths` is preceded in wt_200k_samples.c by a comment
# mentioning `eas_samples`, and a loose match resolves it to the 13,000-line
# eas_samples array above it, reporting a difference that does not exist. That
# false alarm was hit for real while measuring this bank; the anchor is what
# prevents the guard from re-manufacturing it.
# The files our CMake configuration actually compiles the bank from. This list
# is NOT a convenience -- a glob over lib_src/*.c is WRONG. Three files declare
# these same array names, and two of them are not in this build:
#
#   hybrid_22khz_mcu.c   only with EAS_HYBRID_SYNTH, which is undef here
#   wt_44khz.c           only with USE_44KHZ, which is OFF here
#
# hybrid_22khz_mcu.c sorts before wt_22khz.c, so a glob picks it first and the
# guard ends up certifying a bank the app does not ship -- passing while the
# real instruments change underneath it. Measured 2026-08-18; this is the trap
# that motivated pinning the list.
BANK_FILES="wt_22khz.c wt_200k_G.c wt_200k_samples.c"

array_body() { # name
    local name="$1" b f found="" start
    for b in $BANK_FILES; do
        f="$SRC/arm-wt-22k/lib_src/$b"
        if [ -f "$f" ] && grep -q "^\(static \)\?const [A-Za-z_0-9]* ${name}\[" "$f"; then
            found="$f"
            break
        fi
    done
    [ -n "$found" ] || return 1
    start="$(grep -n "^\(static \)\?const [A-Za-z_0-9]* ${name}\[" "$found" | head -1 | cut -d: -f1)"
    # One awk, not `sed -n 'N,$p' | sed -n '/^};/q;p'`. The second sed quits at
    # the closing brace, which SIGPIPEs the first -- and under `set -o pipefail`
    # that fails the whole pipeline. It only bites when the text left unread
    # exceeds the 64K pipe buffer, so the small arrays passed and eas_samples
    # (~650K still to write) failed. A size-dependent failure in a guard is
    # worse than a consistent one; awk reads the file once and exits cleanly.
    awk -v start="$start" 'NR > start { if ($0 ~ /^};/) { exit } print }' "$found" \
        | tr -d ' \t\r' | sed 's|/\*.*\*/||' | grep -v '^$'
}

hash_of() { # name
    array_body "$1" | shasum -a 256 | cut -d' ' -f1
}

ARRAYS="eas_articulations eas_regions eas_programs eas_banks eas_samples eas_sampleLengths eas_sampleOffsets"

if [ "${1:-}" = "--print" ]; then
    [ -d "$SRC" ] || err "no sonivox checkout at $SRC to read hashes from"
    for a in $ARRAYS; do
        h="$(hash_of "$a")" || err "array $a not found in $SRC"
        echo "EXPECT_$a=\"$h\""
    done
    exit 0
fi

if [ ! -d "$SRC" ]; then
    echo "skip - no sonivox checkout at $SRC (run: mise run build-deps)"
    exit 0
fi

for a in $ARRAYS; do
    # eval, because bash 3.2 has no associative arrays. The names are literals
    # from ARRAYS above, never external input.
    eval "want=\$EXPECT_$a"
    if ! got="$(hash_of "$a")"; then
        err "array $a is missing from $SRC/arm-wt-22k/lib_src -- the checkout is incomplete or the upstream layout changed"
    fi
    if [ "$got" != "$want" ]; then
        err "instrument bank changed: $a differs (expected $want, got $got). A sonivox pin bump altered what players hear; listen before accepting, then regenerate with --print."
    fi
done

# The bank can be perfect while the synth runs at the wrong rate, width, or
# channel count. Absent header = fail, NOT a quiet pass on the arrays alone:
# "the instruments are right and I could not check the format" is a different
# claim from "the sound is right", and collapsing them is how a guard ends up
# certifying something it never looked at.
[ -f "$OPTS" ] || err "no generated options header at $OPTS -- the dependency was not built or not installed; run: mise run build-deps"

# Anchored on both ends. Without the trailing boundary, `_SAMPLE_RATE_22050`
# also matches a hypothetical `_SAMPLE_RATE_220500`, and `_8_BIT_SAMPLES`
# matches `_8_BIT_SAMPLES_EXTRA` -- a guard that accepts a macro it was not
# looking for is not asserting anything.
require_define() { # macro   (exact name, value optional)
    grep -Eq "^#define[[:space:]]+$1([[:space:]]|\$)" "$OPTS"
}
reject_define() { # macro
    ! grep -Eq "^#define[[:space:]]+$1([[:space:]]|\$)" "$OPTS"
}

require_define "_SAMPLE_RATE_22050" \
    || err "generated options do not define _SAMPLE_RATE_22050 -- check USE_44KHZ=OFF in Scripts/build-deps.sh"
require_define "_8_BIT_SAMPLES" \
    || err "generated options do not define _8_BIT_SAMPLES -- check USE_16BITS_SAMPLES=OFF in Scripts/build-deps.sh"
# i_easmusic.c reports AL_FORMAT_STEREO16 to OpenAL. A mono build makes that
# report a lie, and the symptom is garbled audio rather than a build failure.
require_define "NUM_OUTPUT_CHANNELS[[:space:]]+2" \
    || err "generated options are not stereo -- i_easmusic.c reports AL_FORMAT_STEREO16 and would be lying"

# Assert the negatives too. The generator emits the unselected option as
# `/* #undef _SAMPLE_RATE_44100 */`, so this cannot fire today -- which is
# exactly why it is cheap to state now, before some later generator change
# makes "both are defined" reachable and the positive checks alone keep
# passing.
reject_define "_SAMPLE_RATE_44100" \
    || err "generated options define BOTH sample rates -- the synth's actual rate is whichever the headers resolve last, so this cannot be certified"
reject_define "_16_BIT_SAMPLES" \
    || err "generated options define BOTH sample widths -- see above"

echo "ok - SONiVOX EAS bank matches its recorded instruments"
