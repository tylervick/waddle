# ZIPFoundation inflates past an entry's declared size

Read in ZIPFoundation 0.9.20 (the pinned version) on 2026-11-23, fixing issue
#516. The check is `ZipExtractor.extract(_:from:to:writtenTotal:totalLimit:)`
and `ZipExtractorTests.testAnEntryLargerThanItsHeaderSaysIsStopped`. This file
covers what those do not say.

## What the library does

`Archive.extract(_:to:)` and `Archive.extract(_:consumer:)` read a deflated
entry by its *compressed* size (`readCompressed` passes
`effectiveCompressedSize` to `Data.decompress`) and hand every inflated chunk
on until the compressed bytes run out. Nothing compares the output with
`Entry.uncompressedSize`. The URL variant does not check the CRC either: it
returns the checksum and leaves the comparison to the caller.

So a cap on `entry.uncompressedSize` limits only what the header *says*. A
zip whose header declares 16 bytes and inflates to gigabytes passes it. Count
the bytes in the consumer and throw once they pass the declared size.

## Building a lying header in a test

ZIPFoundation writes no data descriptor (general-purpose flag 2048 only), so
the declared size lives in two places: the local file header at offset 22
and the central directory header at offset 24, both little-endian `UInt32`.
`Entry.uncompressedSize` reads the central directory one. Patch both;
`ZipFixtures.lyingZip(in:realSize:declaredSize:)` does, and its test checks
the patch took before relying on it.

## One real-bytes stop is enough, and a second one is dead code

The declared sizes are summed against the total cap before anything is
written, and each entry is stopped at its own declared size while it is
written. Both read the same `uncompressedSize` (the central directory's, or a
data descriptor's when there is one) for the same entries, so the bytes
written can never pass the total cap. An earlier version of #521 also kept a
running total of the real bytes and stopped at the cap. The review's mutation
showed it never fired, on 22 hostile archives: it was dead code, and it is
gone.

It did hide something while it was there. With the declared-total check
removed, the honest three-entry test (three 512 KB entries against a 1 MB
cap) was still refused, by that running total and not by the per-entry stop,
which honest entries never trip. So that test could not show the declared
check existed. With the running total gone, removing the declared check lets
that archive through, and the test fails as it should. A guard that duplicates
another is not harmless: it can make the tests of the one that matters pass
without it.

If a later change makes the two loops read different sizes (the local
header's in one of them, say), that proof no longer holds. Re-check it then
rather than restoring the running total by reflex.
