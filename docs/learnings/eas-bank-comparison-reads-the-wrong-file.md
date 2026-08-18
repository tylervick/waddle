# Comparing the EAS instrument bank: two ways to read the wrong thing

Verifying that a `sonivox` pin still carries the predecessor apps' instruments
looks like hashing a file. It is not, and both obvious approaches are wrong in
ways that pass.

**A whole-file hash reports a difference that does not exist.** Upstream split
one 1.39 MB `wt_22khz.c` into `wt_22khz.c` (articulations, regions),
`wt_200k_G.c` (programs, banks) and `wt_200k_samples.c` (PCM, 8- and 16-bit
variants). Every array is byte-identical to the predecessor's; only their
addresses moved. Read the wrong way this costs a day chasing nothing — or gets
a real instrument change waved through as "that file always differs".

**A glob over `lib_src/*.c` reads a bank the app does not ship.** Three files
declare `eas_articulations`, `eas_regions`, `eas_programs`, `eas_banks` and
`eas_samples`: our `wt_22khz.c` / `wt_200k_G.c` / `wt_200k_samples.c`, plus
`hybrid_22khz_mcu.c` (compiled only with `EAS_HYBRID_SYNTH`) and `wt_44khz.c`
(only with `USE_44KHZ`). Both of those are off in this build. Worse,
`hybrid_22khz_mcu.c` sorts alphabetically *before* `wt_22khz.c`, so a glob picks
it first and certifies instruments nobody hears. That is not hypothetical — it
is what the guard did on its first run, and it reported success.

`Scripts/check-eas-bank.sh` is the check. It pins the file list to what this
configuration compiles, anchors on each array's declaration line, and separately
asserts the generated options still select 22 kHz, 8-bit and stereo — a bank
comparison that passes while the synth runs at 44 kHz proves nothing about what
a player hears. `Scripts/test-check-eas-bank.sh` case 13 is the one that keeps
the file list pinned: it plants a decoy bank in a not-compiled file and fails if
the verdict moves.
