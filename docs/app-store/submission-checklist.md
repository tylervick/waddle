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
- [ ] **Xcode signed in** with the developer Apple ID **tylerjvick@gmail.com**
      (Xcode → Settings → Accounts) — this is the Apple ID that holds the
      Developer Program membership for team `352UZEKYPP`. An earlier attempt
      signed in as the wrong account (`kagi@tylervick.com`) and the export
      failed with `DVTDeveloperAccountManager: Failed to load credentials …
      missing Xcode-Token`. Make sure tylerjvick@gmail.com is added and
      shows team 352UZEKYPP with an Apple Distribution capability; remove
      the stale kagi@tylervick.com account if it lingers.
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
      unblocks `xcodebuild -exportArchive` / upload. This is done — builds
      have shipped since.

## 2. Build and upload

**Releases run from CI.** Dispatch the `TestFlight` workflow — do not archive
by hand unless CI is unavailable.

- [ ] **Preflight** (do this first whenever signing, certificates or profiles
      have changed). Builds, signs, exports and validates against App Store
      Connect **without consuming a build number**:

      ```sh
      gh workflow run testflight.yml --ref main -f validate_only=true
      ```

      It catches a signing failure for free — it caught three distinct ones
      before the first real upload ever worked.

- [ ] **Release.** This uploads for real and consumes a build number. Note
      `validate_only` defaults to `false`, so the bare command *is* the real
      upload — there is no safety net here beyond having run the preflight:

      ```sh
      gh workflow run testflight.yml --ref main
      ```

      Or from the UI: Actions → **TestFlight** → Run workflow, ticking
      **validate_only** for a preflight.

- [ ] `build_number` (either mode) overrides the derived number. Only needed
      when retrying a release whose upload already landed server-side.
- [ ] The build number is derived automatically as `200 + run_number`; there
      is nothing to bump in `App/project.yml` any more. It is validated
      (numeric, above the consumed 1–6) *before* the build starts, and the
      number used is written to the run summary.
- [ ] **Confirm the build appears in App Store Connect.** A green run is not
      proof of delivery: Xcode 26's `altool` has been observed reporting
      "Successfully uploaded" for an upload that did not happen.
      `Scripts/upload.sh` greps the output for `ERROR ITMS-` markers rather
      than trusting the exit code, which narrows that window but does not
      close it. The run also records a Delivery UUID — check for that.
- [ ] The signed `.ipa` is attached to the run as an artifact (7-day
      retention) if you need to inspect exactly what shipped.

**Signing assets and their expiry.** Both lapse on **2027-05-02** — the
provisioning profile is bound to the certificate and cannot outlive it.
Neither failure announces itself as an expiry; both surface as opaque signing
errors.

| Asset | Secret | Note |
|---|---|---|
| Apple Distribution certificate | `BUILD_CERTIFICATE_BASE64` + `P12_PASSWORD` | |
| `WADdle App Store CI` profile | `PROVISIONING_PROFILE_BASE64` | **Manually managed.** Xcode refuses an Xcode-managed profile under manual signing, so this cannot be the "iOS Team Store Provisioning Profile" Xcode maintains. |
| App Store Connect API key | `ASC_PRIVATE_KEY` + `ASC_KEY_ID` + `ASC_ISSUER_ID` | |

The profile name appears in **two** places that must agree —
`App/project.yml`'s Release `PROVISIONING_PROFILE_SPECIFIER` and
`App/ExportOptions-ci.plist` — because the archive and the export resolve it
independently. Drift between them fails at *export*, after a full archive has
already been paid for.

**Falling back to a manual release** (CI unavailable): `Scripts/archive.sh`
still works locally and is unchanged by CI — with no environment set it
produces exactly the command lines it always did, using the automatic-signing
`App/ExportOptions.plist`. Then `Scripts/upload.sh`. Note `App/project.yml`
no longer tracks the build number, so set `CURRENT_PROJECT_VERSION` yourself
and pick a value above the highest already in App Store Connect.
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

## 4. App Privacy + age rating + content rights

- [ ] **Content rights — a hard submission gate.** Submission is blocked
      until `contentRightsDeclaration` is answered; it starts `null` and
      nothing prompts for it until the submit flow refuses with *"Apps that
      contain, show, or access third-party content must have all the
      necessary rights to that content…"*. The API accepts exactly
      `DOES_NOT_USE_THIRD_PARTY_CONTENT` or `USES_THIRD_PARTY_CONTENT`.

      **Answer: `USES_THIRD_PARTY_CONTENT`** (set 2026-08-13). Three
      counts, all with rights in hand — declaring otherwise would be false
      for an app that ships Freedoom and is a GPL source port:

      | Content | Rights basis |
      |---|---|
      | Freedoom Phase 1 + 2 (bundled) | BSD, redistribution permitted; `FREEDOOM-COPYING.txt` ships in the bundle |
      | Woof! engine (Boom/MBF lineage) | GPL-2.0, redistribution permitted; `COPYING` at repo root, source public |
      | User-imported WADs | Accessed, never distributed — user-supplied, stays on device |

      This is an attestation that the *owner* holds those rights, so it is
      the owner's to make, not an agent's.

- [ ] **App Privacy:** "Data Not Collected" across the board — the app
      makes no network requests and collects nothing (matches
      `App/PrivacyInfo.xcprivacy`: `NSPrivacyCollectedDataTypes` empty,
      `NSPrivacyTracking` false, UserDefaults reason CA92.1 and
      FileTimestamp only). The answer never changes, but the questionnaire
      must still be **completed and published once** — that is the gate,
      not the value. Web UI only: App Privacy is absent from the REST API
      entirely (`appDataUsages` and friends 404 at the resource level), so
      it cannot be scripted or even inspected from a tool.

      The on-device diagnostics export does not change this. Nothing is
      transmitted — the app links no networking APIs at all — and
      `AboutView` discloses the behaviour in-app.
- [ ] **Age rating:** answer the questionnaire exactly per the §8 table,
      which covers all 29 `ageRatingDeclaration` fields. Three answers are
      non-None — Cartoon/Fantasy Violence: Frequent/Intense; **Guns or
      Other Weapons: Frequent/Intense**; Realistic Violence:
      Infrequent/Mild — and everything else is None/No. Expected result
      **13+** under the 2025 tiers (each of those three is independently a
      13+ descriptor). Leave all override fields at `NONE`; if the form
      resolves higher anyway, accept it rather than walking an answer back.

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
