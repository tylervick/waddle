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

## The real-bytes total stop cannot be tested on its own

With the declared total checked before extraction and each entry stopped at
its declared size, the bytes written can never pass the total cap. The
running-total stop is defence in depth; no archive makes it the only check
that fires. Likewise, a test of the total cap made from honest entries
(three 512 KB entries against 1 MB) passes with the declared-total check
removed, because the per-entry real-bytes stop still refuses it. The test
that pins the declared check uses a header that declares *more* than the
entry holds.
