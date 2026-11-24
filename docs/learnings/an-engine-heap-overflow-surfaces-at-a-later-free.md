# An engine heap overflow surfaces at a later free, not at the write

Measured on 2026-11-24 fixing issue #527 (`I_InitDiskFlash` drew a WAD's
`STDISK` patch uncropped into a 16x16 buffer). The check is
`OversizedDiskIconTests`; this file says why it is shaped the way it is.

## What happened with the fix reverted

A 64x64 `STDISK` writes well past `diskflash` at every video init, yet:

- A session that only reaches the title screen ran its full 8 s autoquit and
  exited 0. Nothing read the bytes it trampled before the session ended.
- A session that warps into E1M1 ended at once in `I_Error` with
  `Z_Free: freed a pointer without ZONEID`: level setup frees zone blocks,
  and the zone's header check is what notices.
- The next session in the same process segfaulted in
  `mz_zip_reader_extract_to_mem_no_alloc1`, reading `woof.pk3` from
  `D_DoomMain`, because the corruption outlives the session (the zone and
  miniz's state live in the app's process).

So "it loaded and showed the title" proves nothing about an out-of-bounds
write in the engine. Drive the session into a level, then start a second
session in the same launch, before calling a fixture harmless; that is
enough to fail without AddressSanitizer for a write of this size. A write of
a few bytes may still need ASan.
