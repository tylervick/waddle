# MIDI Wavetable Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give WADdle the predecessor apps' MIDI music by adding SONiVOX EAS as a wavetable music device, registered ahead of OPL3 and made the default.

**Architecture:** SONiVOX EAS arrives as a third pinned dependency built by `Scripts/build-deps.sh`, exactly like SDL3 and OpenAL Soft — no new build machinery. Inside the engine it becomes one new `stream_module_t`, `i_easmusic.c`, modelled on `i_oplmusic.c`: both are software synths that feed the OpenAL streaming music path rather than talking to an external device. Two guard scripts protect what a future dependency bump could silently break — the instrument bank's identity, and synthesis keeping ahead of playback.

**Tech Stack:** C (Woof engine, SONiVOX EAS), CMake + Ninja cross-compiled for iOS arm64, bash guard scripts, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-17-midi-wavetable-design.md`

## Global Constraints

- Pin: `pedrolcl/sonivox` at tag **`v4.0.1`**, cloned from `https://github.com/pedrolcl/sonivox.git`.
- Sound-determining CMake options, exact values: **`USE_44KHZ=OFF`** and **`USE_16BITS_SAMPLES=OFF`**. These two produce `_SAMPLE_RATE_22050` and `_8_BIT_SAMPLES` in the generated `eas_options.h`. Changing either changes what a player hears.
- Remaining options: `BUILD_SHARED_LIBS=OFF`, `NEW_HOST_WRAPPER=ON`, `SF2_SUPPORT=OFF`, `ZLIB_SUPPORT=OFF`, `EAS_WT_SYNTH=ON`, `EAS_FM_SYNTH=OFF`, `BUILD_TESTING=OFF`, `BUILD_APPLICATION=OFF`. `NEW_HOST_WRAPPER=ON` is what supplies the in-memory reader; without it the module cannot be written at all.
- Device name string, exact: **`"SONiVOX EAS Wavetable"`**. It is API — the migration in Task 6 and Woof's own restore-by-name both match on it.
- `WITH_SNDFILE=OFF`, `WITH_FLUIDSYNTH=OFF`, `WITH_XMP=OFF` all **stay off**. Streamed and tracker music is a separate issue and must not ride along.
- The Woof pin stays master `798acebd`. This plan patches the vendored tree, as this repo already does seven times over; it does not move the pin.
- iOS deployment target `26.0`, arm64, device + simulator — whatever `build-deps.sh` already uses, not a second copy of those values.
- Combined-work license becomes **GPL-3.0** (Apache-2.0 EAS + GPL-2.0-or-later Woof). Do not claim bit-identity with the predecessor's output anywhere — the bank is identical, 42 of 75 core sources are not.
- macOS ships **bash 3.2.57**. No associative arrays, no `${var^^}`.
- Every `Scripts/check-*.sh` gets a `Scripts/test-check-*.sh` beside it, registered in `.github/workflows/ci.yml` → "Verify the build-script helpers".
- Never edit or delete a test to make it pass.
- Conventional commits; work lands through a PR, never on `main`.
- Branch already exists: `tylervick/midi-wavetable-design`.

---

## File Structure

**New files**

| File | Responsibility |
|---|---|
| `Engine/woof/src/i_easmusic.c` | The EAS `stream_module_t`. MUS/MIDI in, PCM out. The only new engine source. |
| `Scripts/check-eas-bank.sh` | Refuses a `sonivox` pin whose instrument bank or sample-rate/sample-width options changed. |
| `Scripts/test-check-eas-bank.sh` | Hermetic suite for the above. |
| `Scripts/eas-realtime-probe.c` | Tracked, compiled harness that renders a MIDI fixture and reports the real-time factor. |
| `Scripts/check-eas-realtime.sh` | Compiles and runs the probe; refuses a synth that cannot stay ahead of playback. |
| `Scripts/test-check-eas-realtime.sh` | Hermetic suite for the above. |
| `Scripts/fixtures/eas-realtime.mid` | Fixed MIDI input for the probe. |
| `docs/learnings/eas-bank-reorganised-not-changed.md` | The reorganised-vs-changed trap, pointing at `check-eas-bank.sh`. |

**Modified files**

| File | Change |
|---|---|
| `Scripts/build-deps.sh` | `SONIVOX_TAG`, a third `fetch`, a `build` per platform. |
| `Scripts/test-build-deps.sh` | Extend the existing fixture to cover the third checkout. |
| `Scripts/build-engine.sh` | `-DWITH_SONIVOX=ON`. |
| `Engine/woof/CMakeLists.txt` | `option(WITH_SONIVOX)` → `find_package` → `set(HAVE_SONIVOX TRUE)`. |
| `Engine/woof/config.h.in` | `#cmakedefine HAVE_SONIVOX`. |
| `Engine/woof/src/CMakeLists.txt` | Conditionally add `i_easmusic.c` and link `sonivox::sonivox`. |
| `Engine/woof/src/i_oalstream.h` | `extern stream_module_t stream_eas_module;` |
| `Engine/woof/src/i_oalmusic.c:39,65` | Register in `all_modules[]` and `midi_modules[]`, ahead of OPL. |
| `Engine/woof/src/i_sound.c` | One-shot migration of a stored OPL3 selection. |
| `.github/workflows/ci.yml` | Register both new suites; run both new guards. |
| `docs/learnings/INDEX.md` | One line for the new learning (`check-substrate.sh` enforces the bijection). |
| `README.md:70-82`, `COPYING`, `App/Resources/Licenses/*` | Relicense to GPL-3.0 and add the SONiVOX notice. Ships in the app's About screen, so it is user-visible, not bookkeeping. |

Why the probe is a **tracked `.c` file** rather than a heredoc a script writes: #158 is an open issue in this repo about exactly that failure — a test generated at run time is a test the compiler never sees, and it drifted silently into producing wrong output. Do not reintroduce the pattern here.

---

## Task 1: Pin and build SONiVOX EAS for iOS

**Files:**
- Modify: `Scripts/build-deps.sh:4-6` (pin block), and the per-platform loop at `:70-91`
- Test: `Scripts/test-build-deps.sh`

**Interfaces:**
- Consumes: nothing — this is the first task.
- Produces: `Vendor/src/sonivox` (checkout at `v4.0.1`), and installed into `Vendor/out/{iphoneos,iphonesimulator}` — headers under `include/`, `libsonivox.a` under `lib/`, and a CMake package config exporting the target **`sonivox::sonivox`**. Tasks 2, 3 and 4 all depend on these paths.

- [ ] **Step 1: Write the failing test**

`Scripts/test-build-deps.sh` already builds throwaway upstream repos and repoints the script's clone URLs at them. Extend that fixture rather than writing a parallel one.

Add a third upstream beside the existing two (near the `make_upstream "$TMP/upstream-openal"` line):

```bash
make_upstream "$TMP/upstream-sonivox"
```

Add a third `sed -e` rewrite inside `make_fixture`, alongside the SDL and openal-soft rewrites:

```bash
        -e "s|https://github.com/pedrolcl/sonivox.git|file://$TMP/upstream-sonivox|" \
```

And a third assertion that the rewrite applied, matching the two already there:

```bash
    grep -q "file://$TMP/upstream-sonivox" "$1/Scripts/build-deps.sh" \
        || fail "fixture did not repoint the sonivox clone URL -- this test would hit the network"
```

Then add a case asserting the third checkout lands at its pin. Follow the numbering already in the file:

```bash
# N. All three dependencies are checked out at their pinned tags. sonivox is
# the one that carries the instrument bank, so a checkout silently left at some
# other tag is a change to what the player hears, not just a build detail.
run_fixture "$TMP/case-sonivox"
[ -d "$TMP/case-sonivox/Vendor/src/sonivox" ] \
    || fail "sonivox was never checked out"
got="$(git -C "$TMP/case-sonivox/Vendor/src/sonivox" rev-parse HEAD)"
want="$(git -C "$TMP/upstream-sonivox" rev-parse v1^{commit})"
[ "$got" = "$want" ] || fail "sonivox checkout is not at its pinned tag"
pass "sonivox is checked out at its pin"
```

Read the existing cases first and match how they invoke the fixture — the helper name and the tag the fixture pins (`v1`/`v2`) are established there; reuse them rather than inventing new ones.

- [ ] **Step 2: Run test to verify it fails**

Run: `Scripts/test-build-deps.sh`
Expected: FAIL with `fixture did not repoint the sonivox clone URL` — the real script has no such URL yet, so the guard rewrite finds nothing.

- [ ] **Step 3: Write minimal implementation**

In `Scripts/build-deps.sh`, add the pin beside the other two:

```bash
SDL_TAG="release-3.4.12"
OPENAL_TAG="1.25.2"
SONIVOX_TAG="v4.0.1"
```

Add the fetch beside the other two:

```bash
fetch sonivox https://github.com/pedrolcl/sonivox.git "$SONIVOX_TAG"
```

And inside the existing `for platform in iphoneos iphonesimulator` loop, after the openal-soft build:

```bash
    # SONiVOX EAS: the predecessor apps' wavetable synth (#116). The two
    # options that decide what a player hears are USE_44KHZ and
    # USE_16BITS_SAMPLES -- OFF/OFF selects the 22 kHz 8-bit bank the
    # predecessor shipped, and Scripts/check-eas-bank.sh refuses a pin bump
    # that changes either the bank or these options.
    #
    # NEW_HOST_WRAPPER=ON is load-bearing, not a preference: it supplies the
    # EAS_FILE {handle, readAt, size} reader, which is how the engine hands
    # EAS a music lump straight out of a WAD with no file on disk.
    #
    # SF2 and ZLIB stay off so this dependency pulls in nothing else; with
    # both off it needs no external library at all, not even -lm on Apple.
    build "$SRC/sonivox" "$platform" \
        -DBUILD_SHARED_LIBS=OFF \
        -DUSE_44KHZ=OFF -DUSE_16BITS_SAMPLES=OFF \
        -DNEW_HOST_WRAPPER=ON \
        -DSF2_SUPPORT=OFF -DZLIB_SUPPORT=OFF \
        -DEAS_WT_SYNTH=ON -DEAS_FM_SYNTH=OFF \
        -DBUILD_TESTING=OFF -DBUILD_APPLICATION=OFF
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Scripts/test-build-deps.sh`
Expected: PASS, all cases including the new one.

- [ ] **Step 5: Verify the real build produces a real library**

Run: `mise run build-deps`
Expected: succeeds. Then confirm the artifact is what later tasks assume:

```bash
lipo -info Vendor/out/iphoneos/lib/libsonivox.a
otool -l Vendor/out/iphoneos/lib/libsonivox.a | grep -A3 LC_BUILD_VERSION | head -5
grep -E "_SAMPLE_RATE_22050|_8_BIT_SAMPLES" Vendor/out/iphoneos/include/libsonivox/eas_options.h
```

Expected: `architecture: arm64`; `platform 2` (iOS, **not** macOS); both defines present and neither commented out. If `platform` reads 1, the cross-compile flags did not apply and the rest of this plan will link a macOS library into an iOS app.

- [ ] **Step 6: Commit**

```bash
git add Scripts/build-deps.sh Scripts/test-build-deps.sh
git commit -m "feat(audio): pin and build SONiVOX EAS for iOS"
```

---

## Task 2: The bank-identity guard

**Files:**
- Create: `Scripts/check-eas-bank.sh`, `Scripts/test-check-eas-bank.sh`, `docs/learnings/eas-bank-reorganised-not-changed.md`
- Modify: `docs/learnings/INDEX.md`, `.github/workflows/ci.yml:77-107`

**Interfaces:**
- Consumes: `Vendor/src/sonivox` from Task 1.
- Produces: nothing later tasks call. It is a gate.

Read `Scripts/check-simulator-available.sh` and `Scripts/test-check-simulator-available.sh` before starting — that pair is this repo's model for a guard with a clean-skip path and a stubbed hermetic suite.

The bank lives in three files and six arrays:

| Array | File |
|---|---|
| `eas_articulations` | `arm-wt-22k/lib_src/wt_22khz.c` |
| `eas_regions` | `arm-wt-22k/lib_src/wt_22khz.c` |
| `eas_programs` | `arm-wt-22k/lib_src/wt_200k_G.c` |
| `eas_banks` | `arm-wt-22k/lib_src/wt_200k_G.c` |
| `eas_samples` | `arm-wt-22k/lib_src/wt_200k_samples.c` |
| `eas_sampleLengths`, `eas_sampleOffsets` | `arm-wt-22k/lib_src/wt_200k_samples.c` |

- [ ] **Step 1: Write the failing test**

Create `Scripts/test-check-eas-bank.sh`. It builds fake source trees in `$TMP` — no network, no real checkout:

```bash
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

# A minimal tree carrying all six arrays and a generated options header.
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
EOF
}

run() { # dir
    env EAS_SRC="$1" EAS_OPTIONS_H="$1/build/libsonivox/eas_options.h" "$SCRIPT"
}

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

echo "All check-eas-bank tests passed."
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Scripts/test-check-eas-bank.sh`
Expected: FAIL immediately — `Scripts/check-eas-bank.sh` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `Scripts/check-eas-bank.sh`:

```bash
#!/bin/bash
# Refuses a sonivox pin whose instrument bank changed, or whose sample rate or
# sample width moved off the values that reproduce the predecessor apps' sound
# (#116).
#
# Why this is not a file hash: upstream split the 1.39 MB wt_22khz.c into three
# files. A whole-file comparison against the predecessor's copy reports a
# mismatch that is not one -- the bank was reorganised, not changed. This
# extracts the six arrays by name instead, so moving one between files is
# invisible and altering one value is not.
#
# skip  - the sonivox checkout is absent (nobody has run `mise run build-deps`).
# error - the checkout is present but an array is missing, an array changed, or
#         the generated options do not select 22 kHz 8-bit. All fail closed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SRC="${EAS_SRC:-$ROOT/Vendor/src/sonivox}"
OPTS="${EAS_OPTIONS_H:-$ROOT/Vendor/build/sonivox-iphoneos/libsonivox/eas_options.h}"

# Recorded hashes. Regenerate with:  Scripts/check-eas-bank.sh --print
# Do NOT copy these from the design doc -- that measured a different
# normalisation, and a hash that was never produced by this script cannot
# match one that is.
EXPECT_eas_articulations="PASTE"
EXPECT_eas_regions="PASTE"
EXPECT_eas_programs="PASTE"
EXPECT_eas_banks="PASTE"
EXPECT_eas_samples="PASTE"
EXPECT_eas_sampleLengths="PASTE"
EXPECT_eas_sampleOffsets="PASTE"

err() { echo "error: $*" >&2; exit 1; }

# Body of a named array, from its declaration to the closing brace, with
# whitespace and trailing comments removed so formatting churn is invisible.
# Searches every lib_src file, so an array that moves between files still
# resolves -- that is the entire point.
array_body() { # name
    local name="$1" f found=""
    for f in "$SRC"/arm-wt-22k/lib_src/*.c; do
        if [ -f "$f" ] && grep -q "${name}\[" "$f"; then
            found="$f"
            break
        fi
    done
    [ -n "$found" ] || return 1
    awk -v name="$name" '
        $0 ~ name "\\[" { inb = 1; next }
        inb && /^\};/ { exit }
        inb { print }
    ' "$found" | tr -d ' \t\r' | sed 's|/\*.*\*/||' | grep -v '^$'
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

# The bank can be perfect while the synth runs at the wrong rate or width.
if [ -f "$OPTS" ]; then
    grep -q '^#define _SAMPLE_RATE_22050' "$OPTS" \
        || err "generated options do not define _SAMPLE_RATE_22050 -- check USE_44KHZ=OFF in Scripts/build-deps.sh"
    grep -q '^#define _8_BIT_SAMPLES' "$OPTS" \
        || err "generated options do not define _8_BIT_SAMPLES -- check USE_16BITS_SAMPLES=OFF in Scripts/build-deps.sh"
fi

echo "ok - SONiVOX EAS bank matches its recorded instruments"
```

Note the options check is skipped when the header is absent (source checked out, not yet built) but fails closed when present and wrong. The suite's cases 4 and 5 always write one, so both are covered.

- [ ] **Step 4: Fill in the recorded hashes**

Run: `Scripts/check-eas-bank.sh --print`
Paste the seven emitted lines over the `PASTE` placeholders. Then run it against a fixture tree to be sure the suite's baseline agrees:

Run: `Scripts/test-check-eas-bank.sh`
Expected: case 1 fails — the fixture's arbitrary arrays do not hash to the real bank's values.

This is expected and is the last piece of wiring: the suite needs its own recorded values. Give the script a way to be pointed at them, by allowing the expectations to come from the environment when set. Add immediately after the `EXPECT_` block:

```bash
# The suite supplies its own expectations for its fixture trees. Unset in
# normal use, so the recorded values above are what CI enforces.
if [ -n "${EAS_EXPECT_FILE:-}" ]; then
    # shellcheck disable=SC1090
    . "$EAS_EXPECT_FILE"
fi
```

and in the suite, generate the fixture's expectations once and point every case at them, by replacing `run()` with:

```bash
run() { # dir
    env EAS_SRC="$1" \
        EAS_OPTIONS_H="$1/build/libsonivox/eas_options.h" \
        EAS_EXPECT_FILE="$TMP/expect.sh" "$SCRIPT"
}

make_tree "$TMP/baseline"
env EAS_SRC="$TMP/baseline" "$SCRIPT" --print > "$TMP/expect.sh"
```

placed after `make_tree` is defined and before case 1.

- [ ] **Step 5: Run test to verify it passes**

Run: `Scripts/test-check-eas-bank.sh`
Expected: PASS, all seven cases.

Run: `Scripts/check-eas-bank.sh`
Expected: `ok - SONiVOX EAS bank matches its recorded instruments`

- [ ] **Step 6: Prove the guard is not vacuous**

A suite that passes proves the suite ran, not that the guard discriminates. Demonstrate both directions against the **real** checkout and record the output for the PR body:

```bash
# Break it: alter one sample in the real tree.
sed -i '' '0,/^    [0-9-]/s//    999,/' Vendor/src/sonivox/arm-wt-22k/lib_src/wt_200k_samples.c
Scripts/check-eas-bank.sh; echo "exit=$?"
# Restore.
git -C Vendor/src/sonivox checkout -- arm-wt-22k/lib_src/wt_200k_samples.c
Scripts/check-eas-bank.sh; echo "exit=$?"
```

Expected: first run exits non-zero naming `eas_samples`; second exits 0. Paste both into the PR. `Scripts/check-red-green.sh` scores claims of this shape, and claims of exactly this shape have been false in this repo before (PRs #57, #61).

- [ ] **Step 7: Write the learning and index it**

Create `docs/learnings/eas-bank-reorganised-not-changed.md`:

```markdown
# The EAS instrument bank was reorganised, not changed

Comparing `pedrolcl/sonivox`'s wavetable against the predecessor apps' copy by
hashing `wt_22khz.c` reports a mismatch. There is no mismatch. Upstream split
one 1.39 MB file into `wt_22khz.c` (articulations, regions), `wt_200k_G.c`
(programs, banks) and `wt_200k_samples.c` (PCM, 8- and 16-bit variants). All
six arrays are byte-identical; only their addresses moved.

Read the wrong way this costs a day chasing a difference that does not exist —
or, worse, gets a real instrument change waved through as "that file always
differs".

`Scripts/check-eas-bank.sh` is the check. It extracts each array by name across
every `lib_src/*.c`, so relocation is invisible and a changed value is not, and
it separately asserts the generated options still select 22 kHz 8-bit — a bank
comparison that passes while the synth runs at 44 kHz proves nothing about what
a player hears.
```

Add one line to `docs/learnings/INDEX.md`, matching the existing format:

```markdown
- [The EAS instrument bank was reorganised, not changed](eas-bank-reorganised-not-changed.md) — why a file hash lies, and what `check-eas-bank.sh` compares instead
```

Run: `Scripts/check-substrate.sh`
Expected: passes — it enforces the file/index bijection.

- [ ] **Step 8: Register the suite in CI**

In `.github/workflows/ci.yml`, add to the "Verify the build-script helpers" list:

```yaml
          Scripts/test-check-eas-bank.sh
```

That list must name every `Scripts/test-*.sh` suite; its own comment says so, and two suites once ran nowhere on a pull request because it did not.

- [ ] **Step 9: Commit**

```bash
git add Scripts/check-eas-bank.sh Scripts/test-check-eas-bank.sh \
        docs/learnings/eas-bank-reorganised-not-changed.md \
        docs/learnings/INDEX.md .github/workflows/ci.yml
git commit -m "feat(audio): guard the SONiVOX EAS instrument bank against pin drift"
```

---

## Task 3: The real-time-factor guard

**Files:**
- Create: `Scripts/eas-realtime-probe.c`, `Scripts/check-eas-realtime.sh`, `Scripts/test-check-eas-realtime.sh`, `Scripts/fixtures/eas-realtime.mid`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `Vendor/src/sonivox` and a host-buildable sonivox from Task 1.
- Produces: nothing later tasks call.

This is the performance guard the spec requires (§6) and the issue mandates. It measures the **library's** synthesis speed, not `i_easmusic.c`'s — state that limitation in the PR rather than overclaiming. The risk it covers is the real one: wavetable synthesis is sustained CPU work where OPL3 emulation was cheap, and nothing else in this repo would notice it getting slower.

- [ ] **Step 1: Create the MIDI fixture**

The probe needs fixed input. Generate it once and commit it:

```bash
mkdir -p Scripts/fixtures
python3 - Scripts/fixtures/eas-realtime.mid <<'PY'
import struct, sys
def vlq(n):
    b = [n & 0x7f]; n >>= 7
    while n:
        b.append((n & 0x7f) | 0x80); n >>= 7
    return bytes(reversed(b))
ev = b''
ev += vlq(0) + bytes([0xC0, 0x1D])   # ch0 -> overdriven guitar
ev += vlq(0) + bytes([0xC1, 0x21])   # ch1 -> fingered bass
for n, d in [(52, 192), (55, 192), (59, 192), (64, 384)]:
    ev += vlq(0) + bytes([0x90, n, 100])
    ev += vlq(0) + bytes([0x91, n - 24, 90])
    ev += vlq(d) + bytes([0x80, n, 0])
    ev += vlq(0) + bytes([0x81, n - 24, 0])
ev += vlq(0) + bytes([0xFF, 0x2F, 0x00])
trk = b'MTrk' + struct.pack('>I', len(ev)) + ev
hdr = b'MThd' + struct.pack('>IHHH', 6, 0, 1, 96)
open(sys.argv[1], 'wb').write(hdr + trk)
PY
```

Two channels with sustained overlapping notes, so the measurement exercises real voice mixing rather than silence.

- [ ] **Step 2: Write the probe**

Create `Scripts/eas-realtime-probe.c`. It is a tracked, compiled source file on purpose — see #158 for what a generated test costs.

```c
/* Renders a MIDI fixture through SONiVOX EAS and reports the ratio of audio
 * produced to wall clock spent. Feeds the MIDI from MEMORY via the EAS_FILE
 * reader callbacks, which is the same path Engine/woof/src/i_easmusic.c uses,
 * so this measures the arrangement the engine actually runs.
 *
 * Prints one line:  frames=<n> seconds=<s> wall=<w> rtf=<r>
 * Exits non-zero if nothing was rendered or the output is silent -- a probe
 * that measures silence would report a spectacular real-time factor. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "eas.h"
#include "eas_types.h"

typedef struct { const unsigned char *data; int len; } MemLump;

static int mem_read_at(void *h, void *buf, int offset, int size)
{
    MemLump *m = (MemLump *)h;
    int n = size;
    if (offset >= m->len) return 0;
    if (offset + n > m->len) n = m->len - offset;
    memcpy(buf, m->data + offset, n);
    return n;
}

static int mem_size(void *h) { return ((MemLump *)h)->len; }

int main(int argc, char **argv)
{
    FILE *f;
    long len;
    unsigned char *buf;
    const S_EAS_LIB_CONFIG *cfg;
    EAS_DATA_HANDLE eas = NULL;
    EAS_HANDLE stream = NULL;
    EAS_FILE locator;
    MemLump lump;
    EAS_PCM *pcm;
    long frames = 0;
    int peak = 0, i, s;
    struct timespec t0, t1;
    double wall, seconds;

    if (argc < 2) { fprintf(stderr, "usage: %s <midi>\n", argv[0]); return 2; }
    f = fopen(argv[1], "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
    fseek(f, 0, SEEK_END); len = ftell(f); fseek(f, 0, SEEK_SET);
    buf = malloc(len);
    if (fread(buf, 1, len, f) != (size_t)len) { fprintf(stderr, "short read\n"); return 2; }
    fclose(f);

    cfg = EAS_Config();
    if (EAS_Init(&eas) != EAS_SUCCESS) { fprintf(stderr, "EAS_Init failed\n"); return 2; }

    lump.data = buf; lump.len = (int)len;
    memset(&locator, 0, sizeof(locator));
    locator.handle = &lump;
    locator.readAt = mem_read_at;
    locator.size   = mem_size;

    if (EAS_OpenFile(eas, &locator, &stream) != EAS_SUCCESS) {
        fprintf(stderr, "EAS_OpenFile from memory failed\n"); return 2;
    }
    if (EAS_Prepare(eas, stream) != EAS_SUCCESS) {
        fprintf(stderr, "EAS_Prepare failed\n"); return 2;
    }

    pcm = malloc(cfg->mixBufferSize * cfg->numChannels * sizeof(EAS_PCM));
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (i = 0; i < 100000; i++) {
        EAS_I32 got = 0;
        EAS_STATE st;
        if (EAS_Render(eas, pcm, cfg->mixBufferSize, &got) != EAS_SUCCESS) break;
        for (s = 0; s < got * cfg->numChannels; s++) {
            int a = pcm[s] < 0 ? -pcm[s] : pcm[s];
            if (a > peak) peak = a;
        }
        frames += got;
        EAS_State(eas, stream, &st);
        if (st == EAS_STATE_STOPPED || st == EAS_STATE_ERROR) break;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    wall = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;

    EAS_CloseFile(eas, stream);
    EAS_Shutdown(eas);
    free(pcm); free(buf);

    if (frames == 0) { fprintf(stderr, "rendered nothing\n"); return 1; }
    if (peak < 1000) { fprintf(stderr, "rendered silence (peak %d)\n", peak); return 1; }
    if (wall <= 0.0) wall = 1e-9;

    seconds = (double)frames / cfg->sampleRate;
    printf("frames=%ld seconds=%.3f wall=%.4f rtf=%.1f\n",
           frames, seconds, wall, seconds / wall);
    return 0;
}
```

- [ ] **Step 3: Write the failing test**

Create `Scripts/test-check-eas-realtime.sh`. The suite must not compile anything or synthesise anything — it tests the script's *judgement*, with the probe stubbed:

```bash
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
```

- [ ] **Step 4: Run test to verify it fails**

Run: `Scripts/test-check-eas-realtime.sh`
Expected: FAIL — the script does not exist.

- [ ] **Step 5: Write minimal implementation**

Create `Scripts/check-eas-realtime.sh`:

```bash
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

rtf="$(echo "$out" | sed -n 's/.*rtf=\([0-9.]*\).*/\1/p')"
[ -n "$rtf" ] || err "the probe produced no real-time factor: $out"

if [ "$(echo "$rtf < $MIN_RTF" | bc -l)" = "1" ]; then
    err "MIDI synthesis real-time factor is ${rtf}x, below the ${MIN_RTF}x floor. Music will stutter on device before it does here."
fi

echo "ok - MIDI synthesis runs ${rtf}x faster than playback (floor ${MIN_RTF}x)"
```

- [ ] **Step 6: Run test to verify it passes**

Run: `Scripts/test-check-eas-realtime.sh`
Expected: PASS, all five cases.

Run: `Scripts/check-eas-realtime.sh`
Expected: `ok - MIDI synthesis runs <N>x faster than playback (floor 5x)`, with N far above 5. Record N for the PR body.

- [ ] **Step 7: Prove the guard discriminates**

```bash
EAS_MIN_RTF=100000 Scripts/check-eas-realtime.sh; echo "exit=$?"
Scripts/check-eas-realtime.sh; echo "exit=$?"
```

Expected: first exits non-zero naming the measured factor; second exits 0. Paste both into the PR.

- [ ] **Step 8: Register in CI**

Add the suite to "Verify the build-script helpers":

```yaml
          Scripts/test-check-eas-realtime.sh
```

And add a step running both new guards after the dependency build, near the other post-build checks:

```yaml
      - name: Verify the MIDI synthesis path
        run: |
          Scripts/check-eas-bank.sh | tee "$RUNNER_TEMP/eas-bank.txt"
          ! grep -q '^skip - ' "$RUNNER_TEMP/eas-bank.txt"
          Scripts/check-eas-realtime.sh | tee "$RUNNER_TEMP/eas-rtf.txt"
          ! grep -q '^skip - ' "$RUNNER_TEMP/eas-rtf.txt"
```

The re-fail on skip is the same discipline `issue-format.yml` uses: here the dependency is guaranteed to have been built, so a skip can only mean something broke, and a guard that silently skips is indistinguishable from one that always passes.

- [ ] **Step 9: Commit**

```bash
git add Scripts/eas-realtime-probe.c Scripts/check-eas-realtime.sh \
        Scripts/test-check-eas-realtime.sh Scripts/fixtures/eas-realtime.mid \
        .github/workflows/ci.yml
git commit -m "feat(audio): guard MIDI synthesis against falling behind playback"
```

---

## Task 4: Wire SONiVOX into the engine build

**Files:**
- Modify: `Engine/woof/CMakeLists.txt:8-16` (options) and `:165-175` (find_package block)
- Modify: `Engine/woof/config.h.in:11`
- Modify: `Engine/woof/src/CMakeLists.txt:283-291`
- Modify: `Scripts/build-engine.sh:47`

**Interfaces:**
- Consumes: `sonivox::sonivox` installed by Task 1.
- Produces: the preprocessor symbol **`HAVE_SONIVOX`**, defined when the library was found. Task 5 guards its new source with it.

This mirrors the `WITH_FLUIDSYNTH`/`HAVE_FLUIDSYNTH` path already in the tree. Follow it exactly rather than inventing a second convention — the next person to re-pin Woof reads these files as a set.

- [ ] **Step 1: Add the option**

In `Engine/woof/CMakeLists.txt`, beside the existing options at the top:

```cmake
option(WITH_SONIVOX "Use SONiVOX EAS if available" ON)
```

Do **not** add a `VCPKG_MANIFEST_FEATURES` entry — the neighbouring options have one because vcpkg packages them; this dependency arrives from `Scripts/build-deps.sh`.

- [ ] **Step 2: Find the package**

Beside the `WITH_FLUIDSYNTH` block near line 165:

```cmake
if(WITH_SONIVOX)
    find_package(sonivox)
    if(sonivox_FOUND)
        set(HAVE_SONIVOX TRUE)
    endif()
endif()
```

- [ ] **Step 3: Expose it to the compiler**

In `Engine/woof/config.h.in`, beside `#cmakedefine HAVE_FLUIDSYNTH`:

```c
#cmakedefine HAVE_SONIVOX
```

- [ ] **Step 4: Compile and link the module conditionally**

In `Engine/woof/src/CMakeLists.txt`, beside the `HAVE_FLUIDSYNTH` block:

```cmake
if(HAVE_SONIVOX)
    target_sources(woof PRIVATE i_easmusic.c)
    target_link_libraries(woof PRIVATE sonivox::sonivox)
endif()
```

`i_easmusic.c` does not exist until Task 5. That is deliberate: this task ends with the wiring proven inert, and Task 5 is what makes it live. Until then `HAVE_SONIVOX` must not be allowed to turn on — so do Step 5 before building.

- [ ] **Step 5: Turn it on in the engine build**

In `Scripts/build-engine.sh:47`, extend the existing options line:

```bash
        -DWITH_SNDFILE=OFF -DWITH_FLUIDSYNTH=OFF -DWITH_XMP=OFF \
        -DWITH_SONIVOX=ON \
```

and add the prefix path so `find_package(sonivox)` resolves — `CMAKE_PREFIX_PATH` and `CMAKE_FIND_ROOT_PATH` already point at `$OUT/$platform`, which is where Task 1 installs, so verify rather than assume:

Run: `mise run build-engine`
Expected: **fails** at the `target_sources` line, because `i_easmusic.c` is missing. That failure is the proof the wiring is connected; a green build here would mean `find_package` did not find the library and `HAVE_SONIVOX` never got set.

If instead it builds green, `sonivox_FOUND` was false. Diagnose before continuing:

```bash
grep -rn "sonivox" Vendor/build/woof-iphoneos/CMakeCache.txt | head
ls Vendor/out/iphoneos/lib/cmake/sonivox/
```

- [ ] **Step 6: Commit**

```bash
git add Engine/woof/CMakeLists.txt Engine/woof/config.h.in \
        Engine/woof/src/CMakeLists.txt Scripts/build-engine.sh
git commit -m "build(engine): wire SONiVOX EAS into the Woof build"
```

---

## Task 5: The EAS stream module

**Files:**
- Create: `Engine/woof/src/i_easmusic.c`
- Modify: `Engine/woof/src/i_oalstream.h:39-44`
- Modify: `Engine/woof/src/i_oalmusic.c:39-52` and `:65-72`

**Interfaces:**
- Consumes: `HAVE_SONIVOX` from Task 4; `sonivox` headers; Woof's `mus2mid()`, `mem_fopen_read()`, `mem_fopen_write()`, `mem_get_buf()`, `mem_fclose()`, `IsMid()`, `IsMus()`.
- Produces: **`stream_module_t stream_eas_module`**, and the device string **`"SONiVOX EAS Wavetable"`** that Task 6 matches on.

`i_oplmusic.c` is the template — read `I_OPL_OpenStream` at `i_oplmusic.c:1522` before writing, and mirror its structure.

**One trap, and it is the only subtle thing in this task.** OPL converts MUS to MIDI into a `MEMFILE`, then calls `MIDI_LoadFile` which parses the whole buffer *before* `mem_fclose` frees it. EAS does not parse up front — it reads **lazily**, through the `readAt` callback, during rendering. So the converted buffer must be copied into storage this module owns and freed in `I_EAS_CloseStream`. Handing EAS a pointer into a closed `MEMFILE` is a use-after-free that will usually still make noise, which is the worst kind.

- [ ] **Step 1: Write the module**

```c
//
// Copyright(C) 2026 Tyler Vick
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// DESCRIPTION:
//      MIDI music via SONiVOX EAS wavetable synthesis (#116).
//
//      This is the synth the per-game apps WADdle replaces used, so its
//      instruments are the ones long-time players know every track by.
//      Structured after i_oplmusic.c: both are software synths feeding the
//      OpenAL streaming path rather than driving an external device.
//

#include "config.h"

#ifdef HAVE_SONIVOX

#include <string.h>

#include "eas.h"
#include "eas_types.h"

#include "doomtype.h"
#include "i_oalstream.h"
#include "i_printf.h"
#include "memio.h"
#include "mus2mid.h"

static EAS_DATA_HANDLE eas_data;
static EAS_HANDLE eas_stream;
static const S_EAS_LIB_CONFIG *eas_config;
static boolean music_initialized;

// The song, in memory, owned by this module. EAS reads it LAZILY through the
// callbacks below while rendering -- it does not parse up front the way
// MIDI_LoadFile does -- so this must outlive OpenStream and be freed in
// CloseStream. Pointing EAS at a MEMFILE that OpenStream closed is a
// use-after-free that still makes plausible noise.
static unsigned char *song_data;
static int song_length;

static const char *music_format;

static int SongReadAt(void *handle, void *buf, int offset, int size)
{
    (void)handle;
    if (offset >= song_length)
    {
        return 0;
    }
    if (offset + size > song_length)
    {
        size = song_length - offset;
    }
    memcpy(buf, song_data + offset, size);
    return size;
}

static int SongSize(void *handle)
{
    (void)handle;
    return song_length;
}

static void FreeSong(void)
{
    if (song_data)
    {
        free(song_data);
        song_data = NULL;
    }
    song_length = 0;
}

static boolean I_EAS_InitStream(int device)
{
    (void)device; // one device; the menu index is resolved by the caller

    if (music_initialized)
    {
        return true;
    }

    eas_config = EAS_Config();
    if (eas_config == NULL)
    {
        I_Printf(VB_ERROR, "I_EAS_InitStream: EAS_Config returned nothing.");
        return false;
    }

    if (EAS_Init(&eas_data) != EAS_SUCCESS)
    {
        I_Printf(VB_ERROR, "I_EAS_InitStream: EAS_Init failed.");
        return false;
    }

    music_initialized = true;
    return true;
}

static boolean I_EAS_OpenStream(void *data, ALsizei size, ALenum *format,
                                ALsizei *freq, ALsizei *frame_size)
{
    EAS_FILE locator;

    if (!IsMid(data, size) && !IsMus(data, size))
    {
        return false;
    }

    if (!music_initialized)
    {
        return false;
    }

    FreeSong();

    if (IsMid(data, size))
    {
        song_data = malloc(size);
        if (song_data == NULL)
        {
            return false;
        }
        memcpy(song_data, data, size);
        song_length = size;
        music_format = "MIDI (EAS)";
    }
    else
    {
        MEMFILE *instream;
        MEMFILE *outstream;
        void *outbuf;
        size_t outbuf_len;

        instream = mem_fopen_read(data, size);
        outstream = mem_fopen_write();

        if (mus2mid(instream, outstream) == 0)
        {
            mem_get_buf(outstream, &outbuf, &outbuf_len);
            // Copy, do not alias: mem_fclose below frees outbuf, and EAS
            // reads this buffer lazily for the whole song.
            song_data = malloc(outbuf_len);
            if (song_data != NULL)
            {
                memcpy(song_data, outbuf, outbuf_len);
                song_length = (int)outbuf_len;
            }
        }

        mem_fclose(instream);
        mem_fclose(outstream);
        music_format = "MUS (EAS)";
    }

    if (song_data == NULL)
    {
        I_Printf(VB_ERROR, "I_EAS_OpenStream: Failed to load MID.");
        return false;
    }

    memset(&locator, 0, sizeof(locator));
    locator.handle = &song_length; // any non-NULL handle; the buffer is static
    locator.readAt = SongReadAt;
    locator.size = SongSize;

    if (EAS_OpenFile(eas_data, &locator, &eas_stream) != EAS_SUCCESS)
    {
        I_Printf(VB_ERROR, "I_EAS_OpenStream: EAS_OpenFile failed.");
        FreeSong();
        return false;
    }

    if (EAS_Prepare(eas_data, eas_stream) != EAS_SUCCESS)
    {
        I_Printf(VB_ERROR, "I_EAS_OpenStream: EAS_Prepare failed.");
        EAS_CloseFile(eas_data, eas_stream);
        eas_stream = NULL;
        FreeSong();
        return false;
    }

    // Report what the library is actually configured for rather than
    // hard-coded constants, so a build-option change cannot silently
    // desynchronise this module from the synth.
    *format = AL_FORMAT_STEREO16;
    *freq = eas_config->sampleRate;
    *frame_size = eas_config->numChannels * sizeof(short);

    return true;
}

static int I_EAS_FillStream(void *buffer, int buffer_samples)
{
    EAS_I32 rendered = 0;
    EAS_I32 total = 0;
    EAS_PCM *out = (EAS_PCM *)buffer;

    if (!music_initialized || eas_stream == NULL)
    {
        return 0;
    }

    // EAS renders a fixed mixBufferSize per call; the caller asks for an
    // arbitrary count, so loop until filled or the song ends.
    while (total + (int)eas_config->mixBufferSize <= buffer_samples)
    {
        if (EAS_Render(eas_data, out + total * eas_config->numChannels,
                       eas_config->mixBufferSize, &rendered) != EAS_SUCCESS)
        {
            break;
        }
        if (rendered <= 0)
        {
            break;
        }
        total += rendered;
    }

    return total;
}

static void I_EAS_PlayStream(boolean looping)
{
    if (!music_initialized || eas_stream == NULL)
    {
        return;
    }
    EAS_SetRepeat(eas_data, eas_stream, looping ? -1 : 0);
}

static void I_EAS_CloseStream(void)
{
    if (eas_stream != NULL)
    {
        EAS_CloseFile(eas_data, eas_stream);
        eas_stream = NULL;
    }
    FreeSong();
}

static void I_EAS_ShutdownStream(void)
{
    if (!music_initialized)
    {
        return;
    }
    I_EAS_CloseStream();
    EAS_Shutdown(eas_data);
    eas_data = NULL;
    music_initialized = false;
}

static const char **I_EAS_DeviceList(void)
{
    static const char **devices = NULL;
    if (array_size(devices))
    {
        return devices;
    }
    // This exact string is API: i_sound.c's migration and Woof's own
    // restore-by-name both match on it. Do not reword it.
    array_push(devices, "SONiVOX EAS Wavetable");
    return devices;
}

static void I_EAS_BindVariables(void)
{
    // No tunables. The 22 kHz 8-bit reverb/chorus configuration is fixed at
    // build time by Scripts/build-deps.sh and enforced by
    // Scripts/check-eas-bank.sh, because it is what reproduces the
    // predecessor apps' sound rather than a preference.
}

static const char *I_EAS_MusicFormat(void)
{
    return music_format;
}

stream_module_t stream_eas_module =
{
    I_EAS_InitStream,
    I_EAS_OpenStream,
    I_EAS_FillStream,
    I_EAS_PlayStream,
    I_EAS_CloseStream,
    I_EAS_ShutdownStream,
    I_EAS_DeviceList,
    I_EAS_BindVariables,
    I_EAS_MusicFormat,
};

#endif // HAVE_SONIVOX
```

Two details already verified against the tree, so do not re-derive them:

- `array_push`/`array_size` come from `m_array.h`, which `i_oplmusic.c:28` includes. Add `#include "m_array.h"` to the include block above.
- `EAS_SetRepeat(pEASData, streamHandle, repeatCount)` is declared at `eas.h:192`, and its documented convention is `0` = no repeat, `-1` = repeat forever. `looping ? -1 : 0` above is correct as written.

- [ ] **Step 2: Declare it**

In `Engine/woof/src/i_oalstream.h`, beside the other externs:

```c
extern stream_module_t stream_eas_module;
```

- [ ] **Step 3: Register it ahead of OPL3**

In `Engine/woof/src/i_oalmusic.c`, in `all_modules[]`:

```c
static stream_module_t *all_modules[] =
{
#if defined (HAVE_FLUIDSYNTH)
    &stream_fl_module,
#endif
#if defined (HAVE_SONIVOX)
    &stream_eas_module,
#endif
    &stream_opl_module,
```

and in `midi_modules[]`:

```c
static stream_module_t *midi_modules[] =
{
#if defined (HAVE_FLUIDSYNTH)
    &stream_fl_module,
#endif
#if defined (HAVE_SONIVOX)
    &stream_eas_module,
#endif
    &stream_opl_module,
};
```

Order is what makes EAS the default on a fresh install: `I_SetMidiPlayer`'s fallback (`i_sound.c:646-662`) takes the first module that initialises.

- [ ] **Step 4: Build**

Run: `mise run build-engine`
Expected: succeeds. Task 4's deliberate failure is now resolved by the file existing.

- [ ] **Step 5: Verify the device is offered and selected**

Run: `mise run test`
Expected: passes on both destinations. `RealWADTests` failures without the fixtures described in `docs/learnings/simulator-test-hazards.md` are expected and not a regression.

Then confirm on a real session rather than trusting the build — launch the app, open Woof's Audio setup, and check the MIDI player list. Expected: `SONiVOX EAS Wavetable` present and listed **before** the two OPL3 entries, and selected by default on a first run. Music audible on a MIDI-music WAD.

- [ ] **Step 6: Commit**

```bash
git add Engine/woof/src/i_easmusic.c Engine/woof/src/i_oalstream.h \
        Engine/woof/src/i_oalmusic.c
git commit -m "feat(audio): add SONiVOX EAS wavetable music module"
```

---

## Task 6: Move existing installs onto the new default

**Files:**
- Modify: `Engine/woof/src/i_sound.c` — inside `I_InitMusic`, immediately before the name-lookup loop at `:683-690`

**Interfaces:**
- Consumes: the device string `"SONiVOX EAS Wavetable"` from Task 5.
- Produces: a new bound config variable **`waddle_midi_migrated`** (int, default 0).

Woof persists the chosen player as a *string* and recovers the menu index by name on launch. That name lookup is a safety net worth understanding: inserting EAS ahead of OPL3 shifts every OPL index by one, and the lookup silently corrects for it, so nobody lands on the wrong device by accident. It also means an existing install keeps OPL3 forever unless something rewrites that string.

The marker is what makes this a migration and not a policy: a player who deliberately switches back to OPL3 after upgrading must stay there. Without it the rewrite fires on every launch and silently overrules them — a bug, not a default.

- [ ] **Step 1: Write the failing test**

There is no C test harness in this repo, and adding one for fifteen lines is not proportionate. Assert the behaviour where it is observable — three real launches, recorded in the PR body:

| Start state | Expected after launch |
|---|---|
| No config file (fresh install) | `SONiVOX EAS Wavetable` |
| Config with `midi_player_string "OPL3 Emulation: GENMIDI"`, no marker | rewritten to `SONiVOX EAS Wavetable`, marker set |
| Config with `midi_player_string "OPL3 Emulation: GENMIDI"`, marker set | stays `OPL3 Emulation: GENMIDI` |

The third row is the one that discriminates. Run it first, before writing the code, and confirm the *second* row currently fails — an existing OPL3 selection survives today, which is exactly the defect this task fixes.

- [ ] **Step 2: Write the implementation**

In `I_InitMusic`, immediately before the existing `const char **strings = I_DeviceList();` name-lookup loop:

```c
    // WADdle patch (#116): move existing installs onto the wavetable synth
    // once. Woof restores the MIDI player by NAME, so without this an
    // upgrading player keeps OPL3 forever and never hears the parity fix.
    //
    // The marker is why this is a migration and not a policy: someone who
    // deliberately picks OPL3 back must keep it. Rewriting on every launch
    // would silently overrule them.
    if (!waddle_midi_migrated)
    {
        if (!strcasecmp(midi_player_string, "OPL3 Emulation: GENMIDI")
            || !strcasecmp(midi_player_string, "OPL3 Emulation: DMXOPL"))
        {
            midi_player_string = "SONiVOX EAS Wavetable";
        }
        waddle_midi_migrated = 1;
    }
```

Declare the variable beside the other module-level config state near the top of the file:

```c
// WADdle patch (#116): set once, the first time a build carrying the
// wavetable synth runs. See the migration in I_InitMusic.
static int waddle_midi_migrated;
```

and bind it so it persists. `midi_player_string` is bound at `i_sound.c:841`; put this immediately after it, inside the same function:

```c
    // WADdle patch (#116). Bound purely so it survives a launch -- without
    // persistence the migration fires every time and overrules a player who
    // switched back to OPL3.
    BIND_NUM(waddle_midi_migrated, 0, 0, 1,
             "WADdle: MIDI player already migrated to wavetable (internal)");
```

`BIND_NUM` is defined at `m_config.h:40` and expands to `M_BindNum(#name, &name, NULL, v, a, b, ss_none, wad_no, help)` — `ss_none` keeps it out of the setup menus, which is right for an internal marker.

- [ ] **Step 3: Verify all three rows**

Run each state from Step 1 on device or simulator. Expected: the table's right-hand column, all three.

Then prove the marker discriminates rather than merely existing: temporarily invert the guard to `if (1)`, confirm row three now *fails* (a deliberate OPL3 choice gets overwritten), restore, confirm it passes. Record both in the PR — this is the case that separates a migration from a bug.

- [ ] **Step 4: Commit**

```bash
git add Engine/woof/src/i_sound.c
git commit -m "feat(audio): migrate existing installs to the wavetable synth once"
```

---

## Task 7: Relicensing to GPL-3.0, and the notices that ship

**Files:**
- Create: `App/Resources/Licenses/SONIVOX-APACHE2.txt`, `App/Resources/Licenses/APP-LICENSE-GPL3.txt`
- Delete: `App/Resources/Licenses/APP-LICENSE-GPL2.txt`
- Modify: `App/Resources/Licenses/NOTICES.md:3-16`, `README.md:70-82`, `COPYING`
- Check: the About screen that renders `App/Resources/Licenses/`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

**Read this before starting — the scope here is larger than "write it down."** Adding Apache-2.0 code changes the license of the shipped binary, and this repo states its license in four places, one of which is **inside the app**. `README.md:72` says "free software under the **GNU GPL v2**"; `NOTICES.md:3` repeats it; `App/Resources/Licenses/APP-LICENSE-GPL2.txt` is the text a user reads on the About screen; `COPYING` is at the repo root. All four move together or the app ships contradicting itself about its own license.

This is not optional polish. It is the one externally visible consequence of the decision, and the About screen is the copy an end user actually sees.

- [ ] **Step 1: Add the Apache-2.0 text**

The upstream copy is in the checkout — use it rather than pasting from memory:

```bash
cp Vendor/src/sonivox/LICENSE-2.0.txt App/Resources/Licenses/SONIVOX-APACHE2.txt
```

- [ ] **Step 2: Replace the app license text with GPL-3.0**

```bash
curl -fsSL https://www.gnu.org/licenses/gpl-3.0.txt \
    -o App/Resources/Licenses/APP-LICENSE-GPL3.txt
git rm App/Resources/Licenses/APP-LICENSE-GPL2.txt
```

Confirm the file is the real thing before committing (`head -3` should read "GNU GENERAL PUBLIC LICENSE / Version 3, 29 June 2007"). Then check whether the About screen enumerates that directory or names files explicitly:

```bash
grep -rn "Licenses\|APP-LICENSE" App/Sources --include="*.swift" | head
```

If any Swift source names `APP-LICENSE-GPL2.txt`, update it — a renamed resource that nothing points at is a blank About screen, and no test covers that today. Update `App/project.yml` too if the file is listed individually rather than by folder reference.

- [ ] **Step 3: Update NOTICES.md**

Change the header line at `NOTICES.md:3` from GPL v2 to GPL v3, and add the entry. Keep the existing list's voice — each line says what the component is and how it is licensed:

```markdown
Waddle is free software under the GNU GPL v3 (see APP-LICENSE-GPL3.txt).
Complete corresponding source: https://github.com/tylervick/waddle
```

```markdown
- SONiVOX EAS (wavetable MIDI synthesis) — Apache-2.0 (SONIVOX-APACHE2.txt),
  © 2004-2009 Sonic Network Inc. The same synth the predecessor per-game apps
  used. Apache-2.0 is incompatible with GPL-2.0 and compatible with GPL-3.0;
  Woof is GPL-2.0-or-later, and exercising that "or later" grant is what makes
  this combination lawful and why this app is GPL-3.0 rather than GPL-2.0.
```

Also update the Woof line above it if it states GPL-2.0 as the app's terms rather than Woof's own — Woof stays GPL-2.0-or-later; only the *combined work* moves.

- [ ] **Step 4: Update README's licensing section**

At `README.md:70-82`, change "GNU GPL v2" to "GNU GPL v3", point at the renamed license file, and add SONiVOX to the list of bundled and linked components alongside SDL3, OpenAL Soft and ZIPFoundation. State the reason in one clause — a reader who sees a GPL-2 project become GPL-3 with no explanation will assume it was a mistake.

- [ ] **Step 5: Update COPYING**

```bash
curl -fsSL https://www.gnu.org/licenses/gpl-3.0.txt -o COPYING
```

`README.md:72` links to it, so it must match what the README now claims.

- [ ] **Step 6: Leave the parity baseline and the audit table alone**

Do **not** edit `README.md:35` or the table row at `README.md:53`, despite both mentioning this exact gap.

`README.md:35` ("**Wavetable MIDI music** — not OPL3 synthesis") is an item in the **parity baseline** list — a description of what the predecessor apps did, which is what this work is measured against. It was true before this change and stays true after.

The table row at `:53` is part of the 2026-08-13 audit's filing record, and the README says so directly two lines above it: *"This table is that filing record, not a live checklist — each issue carries its own current state."* Deleting closed rows would turn a record into a checklist and destroy the thing it documents.

This step exists because both lines look like obvious edits and are not.

- [ ] **Step 7: Verify**

```bash
Scripts/check-substrate.sh
Scripts/check-name-consistency.sh
grep -rn "GPL v2\|GPL-2.0" README.md App/Resources/Licenses/NOTICES.md
```

Expected: both guards pass. The `grep` should return only lines describing *components'* licenses (Woof, OpenAL Soft), never Waddle's own terms.

Then build and open the About screen. Expected: it renders, and shows GPL-3.0 plus the SONiVOX entry.

- [ ] **Step 8: Commit**

```bash
git add App/Resources/Licenses README.md COPYING App/project.yml
git commit -m "docs(license): relicense to GPL-3.0 for Apache-2.0 SONiVOX EAS"
```

---

## Final verification

- [ ] **Full suite, both destinations**

Run: `mise run test`
Expected: passes. `RealWADTests` failures without fixtures are expected per `docs/learnings/simulator-test-hazards.md`.

- [ ] **Every guard**

```bash
Scripts/test-build-deps.sh
Scripts/test-check-eas-bank.sh
Scripts/test-check-eas-realtime.sh
Scripts/check-eas-bank.sh
Scripts/check-eas-realtime.sh
Scripts/check-substrate.sh
Scripts/check-engine-fresh.sh
```
Expected: all pass; neither new guard prints `skip - `.

- [ ] **On-device listening pass**

No test asserts "this sounds right", so this is not optional. Play a MIDI-music WAD, confirm the music is wavetable rather than FM, and confirm the device shown in Woof's Audio setup is `SONiVOX EAS Wavetable`.

- [ ] **PR body must state**

- The measured real-time factor, and that the floor is deliberately loose.
- Both discrimination proofs (Task 2 Step 6, Task 3 Step 7) with their output.
- The migration's three rows and the inverted-guard proof (Task 6 Step 3).
- That the combined binary is now GPL-3.0.
- That bit-identity with the predecessor is **not** claimed — the bank is identical, 42 of 75 core sources are not.
- That streamed/tracker music silence (`WITH_SNDFILE=OFF`, `WITH_XMP=OFF`) is deliberately out of scope and tracked separately.
