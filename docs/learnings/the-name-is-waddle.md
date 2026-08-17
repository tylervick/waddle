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
- `WADdle App Store CI` — a provisioning-profile name registered in Apple's
  developer portal, confirmed still spelled that way via
  `GET /v1/profiles`. It appears in **both** `App/ExportOptions-ci.plist` and
  `App/project.yml`'s `PROVISIONING_PROFILE_SPECIFIER`, and both must match the
  portal exactly. The guard allows this exact literal in any file rather than
  exempting those files wholesale. Rename it at the next profile regeneration,
  portal first.

  **This was missed once and it was nearly expensive.** The 2026-08-16 rename
  exempted the plist but swept `project.yml`, leaving the build asking for a
  profile that does not exist. Nothing caught it: the guard was satisfied, the
  simulator builds are unsigned, and CI never archives on a pull request. It
  would have surfaced as an opaque signing failure on the next TestFlight
  release. Case 9 of `Scripts/test-check-name-consistency.sh` is the regression
  test.

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
it. Only the paths in the guard's `EXEMPT` list may spell it: `Design/`, the
dated records under `docs/superpowers/`, this file, the guard and its test
suite, and `App/ExportOptions-ci.plist`.

`docs/app-store/submission-checklist.md` is the case that bites. It documents
the provisioning profile by name, but the profile is exempt and the checklist
is not — so the checklist refers to it indirectly and points at
`App/ExportOptions-ci.plist` for the exact string. Renaming the profile in the
portal is what would let both spell it plainly.
