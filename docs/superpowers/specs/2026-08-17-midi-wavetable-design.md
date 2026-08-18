# MIDI wavetable design — SONiVOX EAS as the default music synth

**Date:** 2026-08-17
**Status:** Approved design, pending decomposition
**Context:** #116. Closes the last unresolved item from the 2026-08-13 parity
audit against the per-game apps WADdle replaces (tomkidd DOOM-iOS lineage).
Every other parity gap that audit found has landed; music is what remains.

## 1. The decision

WADdle adopts **SONiVOX EAS** — the same wavetable synth the predecessor apps
used — as an additional MIDI music device, registered ahead of OPL3 and made
the default. OPL3 stays available and selectable.

The owner's stated bar is that a returning player should not be able to tell
WADdle's music from the app it replaces. That bar rules out the alternatives
the issue proposed:

| Path | Verdict |
|---|---|
| FluidSynth + `TimGM6mb.sf2` | A *different* wavetable. Sounds fine, sounds wrong. Also 5.97 MB and a glib dependency. |
| Apple DLS / `kAudioUnitSubType_MIDISynth` | Still needs a bundled bank, still not the predecessor's bank. |
| Stay OPL3 | Rejected. FM synthesis is the specific thing players would notice. |
| **SONiVOX EAS** | **The predecessor's actual synth, bit-identical instrument bank.** |

"The same synth" is not an approximation here. §2 records the measurement.

## 2. What the spike established

Run 2026-08-17 against `pedrolcl/sonivox` `v4.0.1` (a maintained CMake fork of
the AOSP tree) and the predecessor's vendored copy at
`~/Documents/DOOM-iOS/code/embeddedaudiosynthesis/arm-wt-22k`.

**The instrument bank is byte-identical.** Compared component by component,
after normalising whitespace, with array bodies extracted between each
declaration and its closing brace:

| Bank component | Result |
|---|---|
| `eas_articulations[]` | identical |
| `eas_regions[]` (378 lines) | identical |
| `eas_programs[]`, `eas_banks[]` | identical |
| `eas_samples[]` (8-bit PCM) | identical |
| `eas_sampleLengths[]`, `eas_sampleOffsets[]` | identical |

A naive whole-file hash of `wt_22khz.c` reports a mismatch, and that mismatch
is an artefact, not a difference: the fork split one 1.39 MB file into
`wt_22khz.c` (articulations, regions) + `wt_200k_G.c` (programs, banks) +
`wt_200k_samples.c` (PCM, both 8- and 16-bit variants). Both derive from the
same `wt_200k_G.dls`. §4 turns this trap into a check so a future pin bump
cannot be misread in either direction.

**The build configuration reproduces the predecessor's settings exactly.** With
`USE_44KHZ=OFF` and `USE_16BITS_SAMPLES=OFF`, the generated `eas_options.h`
carries `_SAMPLE_RATE_22050`, `_8_BIT_SAMPLES`, `_REVERB_ENABLED`,
`_CHORUS_ENABLED`, `EAS_WT_SYNTH`, `MAX_SYNTH_VOICES 64`,
`NUM_OUTPUT_CHANNELS 2` — matching the 22 kHz reverb/chorus DLS configuration
described at predecessor `code/SDL_shim/ios/SDL_Mixer.m:122-216`.

**It builds for iOS arm64 with no external dependencies.** Configured with the
same flags `Scripts/build-deps.sh` uses, it produces a 381 KB static
`libsonivox.a`, `LC_BUILD_VERSION platform 2`, min 26.0. No glib, no zlib, not
even `-lm` on Apple. The five ARM32 `.s` files in the tree are never assembled;
CMake does not enable the ASM language at all, so arm64 is a non-issue.

**MIDI from memory is a supported API, not a workaround.** `EAS_FILE` is
`{void *handle; int (*readAt)(void*, void*, int, int); int (*size)(void*)}` —
a caller-supplied reader. The predecessor's `EASGlueOpenFile(path)` was working
around an older host layer; the maintained fork takes a buffer directly, which
is exactly the shape Woof hands a music backend.

**End-to-end render, driven the way Woof drives a backend** — MIDI in RAM,
callbacks, `EAS_Render` loop:

```
rendered 114432 frames = 5.19 s of audio
non-silent samples: 228801   peak amplitude: 12009/32767   RMS: 2830.5
render wall-clock: 0.004 s  ->  real-time factor 1229x
```

### The one thing the spike did not prove

The bank is identical and the configuration matches, but **42 of the 75 core
source files differ** from the predecessor's 2004-era copy — including
`eas_wtengine.c`, `eas_wtsynth.c`, `eas_mixer.c`, `eas_reverb.c` and
`eas_chorus.c`. Those are fifteen years of upstream fixes. Same instruments
plus same settings makes the result near-certainly indistinguishable, but
bit-identical output is **not** established.

Do not claim bit-identity in the pull request. If it ever needs settling, the
test is to build the predecessor's tree and diff rendered PCM for one MIDI
input; that is deliberately out of scope here (§8).

## 3. What gets built

Four pieces. The engine-side change is smaller than the input bridge this repo
already carries.

**A pinned dependency.** `Scripts/build-deps.sh` gains a third `fetch` line
beside SDL3 and OpenAL Soft, and a `build` call per platform:

```bash
fetch sonivox https://github.com/pedrolcl/sonivox.git "$SONIVOX_TAG"
...
build "$SRC/sonivox" "$platform" \
    -DBUILD_SHARED_LIBS=OFF \
    -DUSE_44KHZ=OFF -DUSE_16BITS_SAMPLES=OFF \
    -DNEW_HOST_WRAPPER=ON \
    -DSF2_SUPPORT=OFF -DZLIB_SUPPORT=OFF \
    -DEAS_WT_SYNTH=ON -DEAS_FM_SYNTH=OFF \
    -DBUILD_TESTING=OFF -DBUILD_APPLICATION=OFF
```

Every one of those options is load-bearing and §4's check enforces the two that
determine the sound. `NEW_HOST_WRAPPER=ON` is what supplies the memory reader.

**A new stream module, `Engine/woof/src/i_easmusic.c`.** It implements
`stream_module_t` (`i_oalstream.h:25-37`) and follows the shape of
`i_oplmusic.c`, which is the closest existing template — both are software
synths feeding the OpenAL streaming path rather than an external device:

- `I_EAS_OpenStream(data, size, ...)` mirrors `I_OPL_OpenStream`
  (`i_oplmusic.c:1522`): reject unless `IsMid()` or `IsMus()`, convert MUS to
  MIDI in memory via the existing `mus2mid.c`, then point an `EAS_FILE` locator
  at that buffer and call `EAS_OpenFile` / `EAS_Prepare`. No temp file, no path.
- `I_EAS_FillStream(data, frames)` wraps `EAS_Render`.
- `I_EAS_DeviceList()` returns one entry, `"SONiVOX EAS Wavetable"`. That exact
  string is API: §5's migration and Woof's own restore-by-name both match on it,
  so it must not be reworded casually.
- Reported format is 22050 Hz, stereo, 16-bit — `EAS_Config()` supplies these
  rather than hard-coding them, so a future option change cannot silently
  desynchronise the module from the library.

**Registration.** `stream_eas_module` is declared in `i_oalstream.h` and added
to `all_modules[]` and `midi_modules[]` in `i_oalmusic.c:39,65`, **ahead of**
`stream_opl_module`, behind a `HAVE_SONIVOX` guard matching the existing
`HAVE_FLUIDSYNTH` pattern. Ordering is what makes it the default for a fresh
install: `I_SetMidiPlayer`'s fallback path (`i_sound.c:646-662`) takes the first
module that initialises.

**Build wiring.** `Scripts/build-engine.sh` passes `-DWITH_SONIVOX=ON` and the
include/lib paths, alongside the existing `-DWITH_SNDFILE=OFF
-DWITH_FLUIDSYNTH=OFF -DWITH_XMP=OFF`. Those three stay off; see §8.

## 4. The bank-identity guard

`Scripts/check-eas-bank.sh`, run in CI beside the other guards.

This exists because of a specific trap the spike hit: the obvious check —
hashing the bank file — reports a difference that is not one, and would send
the next person down a false trail or, worse, get waved through as "upstream
churn" on a bump that genuinely changed the instruments. The distinction the
check must preserve is between *reorganised* and *changed*.

It extracts each of the six bank arrays in §2 by name, from declaration to
closing brace, normalises whitespace, and compares the hashes against values
recorded in the script. It fails loudly, naming which array diverged, when a
`sonivox` pin bump alters the instruments. It also asserts the two options that
determine the sound — `_SAMPLE_RATE_22050` and `_8_BIT_SAMPLES` — are set in the
generated `eas_options.h`, because a bank comparison that passes while the synth
runs at 44 kHz proves nothing about what a player hears.

`Scripts/test-check-eas-bank.sh` covers it in the manner of the other guard
suites: a stub tree that matches passes; a stub with one altered sample value
fails and names that array; a stub with the arrays intact but `_SAMPLE_RATE_44100`
set fails on the option assertion. Prove each case discriminates by deleting the
corresponding check and confirming the case goes red — `Scripts/check-red-green.sh`
scores this, and PRs #57 and #61 are why.

A learning file under `docs/learnings/` records the reorganised-not-changed trap
in one paragraph and points at this script rather than restating it, per the
repo rule that a learning which can be an executable check becomes one.

## 5. Default device and migration

A fresh install gets EAS from the module ordering in §3. Existing installs need
explicit help, and the owner's decision is that they move.

Woof persists the chosen player as a **string** (`midi_player_string`) and, on
launch, looks it up by name to recover the menu index (`i_sound.c:683-690`).
That name-based restore is a safety net worth understanding: inserting EAS ahead
of OPL3 shifts every OPL index by one, and the name lookup silently corrects for
it. Nobody lands on the wrong device by accident.

It also means a player who already has a build keeps OPL3 forever unless
something rewrites that string. So: a one-shot migration in `i_sound.c`,
immediately before the name lookup in `I_InitMusic`, guarded by a new bound
config variable (`waddle_midi_migrated`, default 0). When the marker is unset
and `midi_player_string` is one of the two OPL3 names, rewrite it to
`"SONiVOX EAS Wavetable"` and set the marker.

The marker is what makes this a migration rather than a policy. A player who
deliberately switches back to OPL3 after upgrading must stay on OPL3 across
every subsequent launch — without the marker, the rewrite would fire again and
silently overrule them, which is a bug, not a default. Clearly comment it as a
WADdle patch; it is app-lifecycle logic living in engine code, and the next
person to re-pin Woof needs to see that immediately.

## 6. Performance guard

The issue requires one, on the reasoning that wavetable synthesis is sustained
CPU work where OPL3 emulation was cheap. It is required, and it will pass with
enormous headroom: the spike measured **1229× real-time** on the dev machine.
Even at a fiftieth of that on device, it is ~24×.

Implement it as the issue specifies — a real-time-factor test that renders a
fixed span of audio from a MIDI fixture and asserts it completes in well under
that span of wall clock, with the 5× margin the issue asks for. State the
measured factor in the pull request. Do not tighten it toward the measured
number: the margin is what keeps it from becoming a flaky benchmark on hosted
runners, and a flaky gate gets ignored, which is worse than no gate.

## 7. Licensing

SONiVOX EAS is **Apache-2.0**. Woof is **GPL-2.0-or-later**
(`Engine/woof/src/d_main.c:7-8`, "either version 2 of the License, or (at your
option) any later version").

Apache-2.0 is incompatible with GPL-2.0 and compatible with GPL-3.0, so the
combined binary ships under **GPL-3.0**. The "or later" grant is what makes this
lawful, and the predecessor shipped this same combination on the App Store.

Record the change and EAS's attribution in the repo's license documentation
alongside the existing third-party notices. This is the only externally visible
consequence of the decision and it should not be discovered later by a reader
diffing licenses.

## 8. Testing and scope

Beyond §4's guard suite and §6's performance test:

- The engine smoke check in `mise run test` must still pass on both
  destinations; adding a music module must not disturb it.
- A device-list assertion: `"SONiVOX EAS Wavetable"` is present and precedes the
  OPL3 entries.
- A migration test covering all three states — unmigrated OPL3 selection moves;
  an already-migrated deliberate OPL3 selection stays; a fresh install with no
  stored string lands on EAS.
- Manual confirmation on device, since no test asserts "this sounds right":
  a MIDI-music WAD, the new device shown in Woof's Audio setup, music audible.

**Out of scope, deliberately:**

- **Streamed and tracker music.** `WITH_SNDFILE=OFF` and `WITH_XMP=OFF` mean
  OGG/FLAC/WAV music lumps and tracker modules in community WADs play silently
  today. That is a real defect and a separate one — two more pinned dependencies
  and a different risk profile. It gets its own issue; it does not ride along.
- **Proving bit-identity with the predecessor** (§2).
- **Any WADdle-side UI for choosing the synth.** The engine's existing Audio
  setup menu is the surface.

## 9. Provenance

Decided in conversation with the owner on 2026-08-17, opening from the
`agent:blocked` pile. The owner set the bar at "exactly the old sound," which
selected EAS over the three paths #116 proposed; chose to split the streamed-music
defect out; and chose active migration over letting existing testers sit on OPL3.

The spike in §2 ran the same day. Its throwaway harness is not retained — the
measurements are recorded here, and §4 is what keeps them true.

Sibling: #79 owns the vendored-pin maintenance question this touches. The
`sonivox` pin lands in `build-deps.sh` beside SDL3 and OpenAL Soft, so it
inherits whatever that issue settles rather than inventing a second scheme.
