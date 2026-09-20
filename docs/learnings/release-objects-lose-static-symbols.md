# A Release-built engine object has no symbol for an initialised `static`

Found 2026-09-20 while building `Scripts/globals-diff.py`, which maps changed
byte ranges in the engine's data sections back to variable names.

`nm` on `Vendor/build/woof-iphonesimulator/src/libwoof.a` lists `_EpiCustom`
(a non-static global), `_lumpinfo`, and `_pristine` (a zero-initialised
`static`, so `__bss`), but nothing at all for `MainDef`, `EpiDef` or
`MainMenu` -- initialised file-scope statics in `mn_menu.c`. clang at `-O3`
(CMake's Release flags) emits those as unnamed section data: no local symbol,
not even an `l_` label, so neither `nm` nor a linker map can name them, and a
byte offset into `__DATA,__data` had nowhere to go.

DWARF can name them. With `-g` added to `CMAKE_C_FLAGS_RELEASE`
(`Scripts/build-engine.sh`), each object carries a `DW_TAG_variable` for every
static, located as `DW_OP_addrx <n>, DW_OP_plus_uconst <offset>` -- an index
into the object's address table plus an offset, which only means something
after linking. `dsymutil` on the linked image (the Debug simulator dylib,
`Waddle.debug.dylib`) resolves it to a final `DW_OP_addr`; `dwarfdump
--debug-info` on the resulting dSYM is what the script parses. Resolved is not
the same as plain: the privatised statics come out as `DW_OP_addr 0x874a30,
DW_OP_plus_uconst 0x58`, the section base plus the offset, and the offset is
part of the address. A parser that stops at the bare `DW_OP_addr` hands every
such variable's bytes to whichever variable sits exactly at the base --
measured: `MainDef.numitems` reported as `EpiMenuEpi+0x58` -- which is why
`Scripts/test-globals-diff.sh` has a case for it. The `.o` files
must still be where the link left them, which for this repository means the
archive under `Vendor/build/`.

The DWARF never reaches the shipped binary. A Debug link keeps a debug map
that points back at the objects; a Release link folds it into the dSYM. The
side benefit is that TestFlight crash reports symbolicate engine frames to
source lines instead of offsets.

`Scripts/check-engine-fresh.sh` notices the flag change through the fingerprint
and refuses the stale framework, so the first build after this lands rebuilds
the engine.
