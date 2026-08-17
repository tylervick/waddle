# The name is "Waddle"; "WADdle" is the wordmark

The app is called **Waddle**. `WADdle` is a *wordmark* — a visual treatment
that makes the **WAD** visible inside the name — and it belongs in `Design/`,
not in typed text. `Scripts/check-name-consistency.sh` is the check.

This has now cost two renames. `BoomBox` → `WADdle` (2026-07) left residue that
survived for weeks, including an `App/BoomBox.xcodeproj` nobody noticed;
`WADdle` → `Waddle` (2026-08-16) is the second. A stylized spelling is
self-camouflaging: it reads as deliberate wherever it lands, so nobody deletes
it on sight. That is why the rule is mechanical rather than remembered.

**Three things are NOT the wordmark and must not be swept:**

- `WADDLE_*` test-seam environment variables — SCREAMING_SNAKE reads
  identically either way.
- The lowercase family: `com.tylervick.waddle`, the `com.tylervick.waddle.*`
  UTIs, `tylervick/waddle`, `Design/waddle-mark.png`, `.waddleScrollSurface()`.
  Changing the bundle ID or UTIs would orphan every installed build's saves and
  document associations.
- `WADdle App Store CI` in `App/ExportOptions-ci.plist` — a provisioning-profile
  name registered in Apple's developer portal. Renaming it here without renaming
  it there breaks CI signing with an opaque error. Rename it at the next profile
  regeneration, portal first.

**Dated records under `docs/superpowers/` are frozen.** They are cited as
provenance by the guard scripts and skill guides, every stale identifier in them
fails loudly at the point of use (`-scheme WADdle` → "scheme not found"), and
sweeping them would fabricate: `2026-07-20-soft-keyboard-input-design.md` reads
`WADdle (com.tylervick.BoomBox)`, recording a window that really existed. When
reading a plan written before 2026-08-16, translate build commands yourself.

**A guard that forbids a spelling cannot quote it.** `INDEX.md`, `ci.yml` and
`docs/app-store/metadata.md` are all outside the exemption list, so the entry
that indexes this file, the CI comment that runs the check, and the store
listing's naming rationale all had to describe the wordmark instead of spelling
it. Only this file and the guard's own source may name it.
