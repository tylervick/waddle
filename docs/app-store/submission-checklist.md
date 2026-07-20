# App Store submission checklist — WADdle

Ordered owner checklist for the first submission. Everything below is a
human-only step (Apple ID sign-in, App Store Connect forms, review
submission). All referenced content is already in this repo:
`docs/app-store/metadata.md` (approved 2026-07-18) holds the exact text to
paste; `docs/app-store/screenshots/` holds the images;
`Scripts/archive.sh` produces the build.

## 0. Prerequisites (one-time)

- [ ] **Apple Developer Program membership** active for team `352UZEKYPP`
      (Tyler Vick). App Store distribution requires the paid program — a
      free "personal team" can device-sign but cannot create App Store
      provisioning or upload builds.
- [ ] **Xcode signed in** with the developer Apple ID (Xcode → Settings →
      Accounts). As of 2026-07-18 the export step failed with
      `DVTDeveloperAccountManager: Failed to load credentials for
      kagi@tylervick.com ... missing Xcode-Token` — re-authenticate that
      account (or remove/re-add it) before exporting.
- [ ] **Repo public** (GPL compliance + the support/privacy URLs below
      must resolve): `gh repo edit tylervick/waddle --visibility public
      --accept-visibility-change-consequences`. Do this BEFORE submitting
      for review — App Review may open the links.

## 1. Create the App Store Connect app record

- [ ] App Store Connect → My Apps → **+** → New App:
  - Platform: **iOS**
  - Name: **WADdle** (§1 of metadata.md; if taken/rejected
    for similarity, fallback options are recorded in the same section)
  - Primary language: **English (U.S.)**
  - Bundle ID: **com.tylervick.waddle** (register it under
    Certificates, Identifiers & Profiles first if it isn't offered in the
    dropdown; no special capabilities needed)
  - SKU: anything stable, e.g. `waddle-ios`
- [ ] Note: creating this record (plus program membership) is what
      unblocks `xcodebuild -exportArchive` / upload. Until it exists,
      export fails with `error: exportArchive No profiles for
      'com.tylervick.waddle' were found` — this is the current state.

## 2. Build and upload

- [ ] `Scripts/archive.sh` — regenerates the project, builds the Release
      archive to `Vendor/archive/WADdle.xcarchive`, and exports a signed
      .ipa to `Vendor/archive/export/`.
- [ ] Upload, either way:
  - **Xcode Organizer:** Window → Organizer → Archives → Distribute App →
    App Store Connect → Upload (skips the manual .ipa entirely), or
  - **Transporter / CLI:** upload `Vendor/archive/export/WADdle.ipa`
    with the Transporter app, or
    `xcrun altool --upload-app -f Vendor/archive/export/WADdle.ipa -t ios
    --apiKey <key> --apiIssuer <issuer>`.
- [ ] Export compliance never prompts at upload:
      `ITSAppUsesNonExemptEncryption = NO` is baked into the Info.plist
      via `App/project.yml`. (Rationale in §9 of metadata.md: no network
      connections, no non-exempt crypto — SHA-1 dedupe hashing is exempt.)
- [ ] Wait for the build to finish processing (email from App Store
      Connect), then select it on the version page.

## 3. Version page — paste from metadata.md

- [ ] **Name / Subtitle:** §1–2 ("WADdle" / "Play classic
      Doom WADs")
- [ ] **Promotional text:** §3
- [ ] **Description:** §4
- [ ] **Keywords:** §5 (`doom,wad,fps,retro,source port,freedoom,boom,classic`)
- [ ] **Support URL:** https://github.com/tylervick/waddle
- [ ] **Privacy Policy URL:**
      https://github.com/tylervick/waddle/blob/main/PRIVACY.md
   (verify this URL resolves (HTTP 200) after PR #4 merges to main, before entering it in App Store Connect)
- [ ] **Category:** Games → Action (§7)
- [ ] **Copyright:** `© 2026 Tyler Vick; engine GPL-2.0` (§10)
- [ ] **Screenshots:** upload from `docs/app-store/screenshots/` in the
      slot order of §12 (6.9" iPhone set + 13" iPad set, six shots each).

## 4. App Privacy + age rating questionnaires

- [ ] **App Privacy:** "Data Not Collected" across the board — the app
      makes no network requests and collects nothing (matches
      `App/PrivacyInfo.xcprivacy`: UserDefaults reason CA92.1 only).
- [ ] **Age rating:** answer the questionnaire exactly per the §8 table
      (Cartoon/Fantasy Violence: Frequent/Intense; Realistic Violence:
      Infrequent/Mild; everything else None/No). Expected result ~13+
      under the 2025 tiers; if it resolves higher, accept it (GenZD ships
      at 17+).

## 5. Review notes + submit

- [ ] Paste the App Review notes from §11 verbatim (GPL source port, only
      Freedoom bundled, no network, demo path: tap "Freedoom Phase 1").
- [ ] **GPL posture check (must all be true before tapping Submit):**
  - Repo is public and the complete corresponding source for the
    submitted build is on `main` (the About screen links to it).
  - `COPYING` (GPL-2.0) at the repo root; Freedoom's BSD license ships in
    the app bundle (`GameData/FREEDOOM-COPYING.txt`) and the About screen
    surfaces all licenses.
  - No copyrighted commercial game content in the repo or the bundle —
    Freedoom only.
- [ ] Submit for review.

## Known limitations (for the record, no action needed)

- A corrupted app container at cold start hits a `fatalError` rather than
  a recovery flow (container-init recovery needs design; risk is
  cold-start-only). Documented as a carried item in the Plan 4 review
  notes.
- Corrupt-entry-only zips inside an otherwise-valid archive import the
  valid entries and quarantine the rest to `Documents/Import Failed/` —
  documented behavior, not a bug.
