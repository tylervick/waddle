# An engine heap overflow surfaces at a later free, not at the write

Measured on 2026-11-24 fixing issue #527 (`I_InitDiskFlash` drew a WAD's
`STDISK` patch uncropped into a 16x16 buffer). The check is
`OversizedDiskIconTests`; this file says why it is shaped the way it is.

## What happened with the fix reverted

A 64x64 `STDISK` writes well past `diskflash` at every video init. What it
breaks, and when, depends on what the heap put next to that buffer, so it
moves from run to run:

- A session that only reaches the title screen ran its full 8 s autoquit and
  exited 0 every time it was tried. Nothing read the bytes it trampled before
  the session ended.
- In the author's run, the first session warped into E1M1 ended at once in
  `I_Error` with `Z_Free: freed a pointer without ZONEID` (level setup frees
  zone blocks, and the zone's header check is what notices). The next session
  in the same process segfaulted in `mz_zip_reader_extract_to_mem_no_alloc1`,
  reading `woof.pk3` from `D_DoomMain`, because the corruption outlives the
  session.
- In the reviewer's three runs, the test failed every time, but at different
  points. In two of them the first warped session reached E1M1 and exited 0,
  and the *second* failed with the same `ZONEID` error (exit -1). In the
  third, the app crashed during the first warped session.

So "it loaded and showed the title" proves nothing about an out-of-bounds
write in the engine, and neither does one clean level. Drive the session into
a level, then start a second session in the same launch: the second video
init frees and reallocates the trampled buffer, and its level setup walks the
zone again. That made the test fail in every run so far, but it is likely,
not guaranteed, because it rests on heap layout. A deterministic check, or a
write of only a few bytes, needs a guarded allocator or AddressSanitizer.
