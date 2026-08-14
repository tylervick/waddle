# A content-hash lookup table fails silently, so its tests must not read it

`IWADCatalog` maps published IWAD content SHA-1s to game titles. Every other
kind of wrong data in this app announces itself — a bad path throws, a bad lump
name fails to parse. A wrong hash does neither. It compiles, it is the right
shape, its lookup returns `nil`, and `nil` is the *designed* answer for every
PWAD and mod ever imported. The failure is indistinguishable from correct
operation until someone imports the real doom2.wad and still sees "doom2".

Two habits contain it, and both are load-bearing:

**Corroborate each entry with a second identifier before adding it.** The
published MD5 sits in a comment beside every SHA-1 in the table for exactly
this reason: the two together came from the same source record, so a
transcription slip in one is caught by the other not matching anywhere else.
Each entry in the initial table was checked against at least two independent
published sources (a distribution's own checksum listing, plus a WAD database
keyed by SHA-1 — its URL *is* the hash, which makes the fetch itself a
verification). One source is a rumor.

**Never let the test build its expectations from the table.** A test that
iterates `titlesBySHA1` to check "every entry resolves" passes against an empty
table, a typo'd table, and a table where every title is wrong — it only ever
proves a dictionary is a dictionary. `IWADCatalogTests` therefore spells the
hash literals out again, one test per game, so deleting a game's row turns
exactly that game's test red. That property was verified by doing it: removing
the Plutonia entry failed `testResolvesThePublishedPlutoniaHash` alone and left
the other eight green.

Structural assertions (all keys are lowercase 40-char hex, no title is empty)
are worth keeping *alongside* the literals — they catch the uppercase or
truncated key that would sit in the table looking plausible forever, since
`WADStore.sha1` only ever emits lowercase hex and would never match it.

**Provenance:** issue #118, 2026-08-14 — titling recognized commercial IWADs.
