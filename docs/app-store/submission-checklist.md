# App Store submission checklist — Waddle

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

- [ ] **`RELEASE_TAG_TOKEN`** in the `app-store` environment. The release
      pushes its `build-<N>` tag with this, not with the job token, because
      the job token may not create a tag on a commit whose workflow files
      differ from `main`'s head, and an on-merge release tags a commit `main`
      moves past while the archive runs (build 277 was uploaded and could not
      be tagged). Mint it at GitHub → Settings → Developer settings →
      Fine-grained personal access tokens: repository access **only this
      repository**; permissions **Contents: Read and write** and
      **Workflows: Read and write** (Metadata read is implied); the longest
      expiry offered. Then:

      ```sh
      gh secret set RELEASE_TAG_TOKEN --env app-store
      ```

      The release checks the token before archiving and warns in the run
      log when it is within 30 days of expiry; GitHub also emails before
      expiry. A release that fails at "Check the tag-push token" uploaded
      nothing: mint a replacement, set it, and dispatch again.

## 1. Create the App Store Connect app record

- [ ] App Store Connect → My Apps → **+** → New App:
  - Platform: **iOS**
  - Name: **Waddle: WAD Player** (§1 of metadata.md — the bare "Waddle" is
    held by another account and is rejected with
    `409 ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE.DIFFERENT_ACCOUNT`; the
    suffix is forced, and alternative suffixes are recorded in the same section)
  - Primary language: **English (U.S.)**
  - Bundle ID: **com.tylervick.waddle** (register it under
    Certificates, Identifiers & Profiles first if it isn't offered in the
    dropdown; no special capabilities needed)
  - SKU: anything stable, e.g. `waddle-ios`
- [ ] Note: creating this record (plus program membership) is what
      unblocks `xcodebuild -exportArchive` / upload. This is done — builds
      have shipped since.

## 2. Build and upload

**Releases run from CI.** Do not archive by hand unless CI is unavailable.

**Builds ship on merge.** `ci.yml` calls the `TestFlight` workflow after its
build and unit tests pass on a push to `main`. A `gate` job asks
`Scripts/release-due.sh` whether anything that goes into the binary changed
since the newest `build-*` tag, and skips the whole release if not, so a
docs-only, test-only or workflow-only merge costs nothing and ships nothing
(the script's `NON_BINARY_PATHS` is the list; a change that lands under a
path not named there ships). Every uploaded build reaches the internal
TestFlight group through that group's **automatic distribution** setting in
App Store Connect; keep the external group's setting **off**, so an outside
tester gets a build only through the promotion below. Nothing in the workflow
adds a build to a group.

**Build numbers** are the newest `build-*` tag plus one, whichever path runs,
so the merge path and the dispatch path count on one sequence. Two merges in
quick succession release one after the other on a shared concurrency group.
The tag is pushed with `RELEASE_TAG_TOKEN` (section 0), which the release
proves present and unexpired before it archives.

**Manual dispatch** (Actions › TestFlight › Run workflow on `main`) is still
how you release *on demand*, and it is never gated: it ships whether or not
`main` moved, which is what makes it the way to re-release after a failed
notes attach or to ship an engine rebuild that changes the binary with no new
commits behind it. Tick `validate_only` for a dry run (no build number
consumed). Leave `build_number` empty unless App Store Connect already holds
a number that no `build-*` tag records, such as an upload made outside CI. A
CI upload whose tag failed to push is repaired by pushing that tag by hand at
the commit that shipped, exactly as the run's error says, never by overriding:
an override uploads a second build, and the next merge still derives the
missing number from the old tag and is rejected.

**The What to Test preamble** (`docs/app-store/whats-to-test.md`) heads the
notes only if it changed since the previous build's tag: it is written for the
next build, and the same text must not go out with every build after. Write
it in the pull request that ships the change it describes; merged on its own
it ships nothing and then heads the next code change's build. Preview with
`Scripts/whats-to-test.sh --print`.

**Promoting a shipped build to external testers** is a tag, not a build
(issue #165): `CFBundleShortVersionString` cannot carry "rc", and rebuilding
would ship bits nobody tested. Pick the internal build that passed its smoke
test and tag its commit:

```
git tag rc-1.1.0 build-231 && git push origin rc-1.1.0
```

`promote-build.yml` resolves the `build-<N>` tag on that commit (exactly one,
or it fails loudly: an `rc-*` tag on a commit that never shipped is the
mistake it exists to catch) and runs `Scripts/promote-build.sh <N> <group>`,
which assigns the existing build to the group named by the repository
variable `TESTFLIGHT_EXTERNAL_GROUP` (set it once, to the group's exact name
in App Store Connect). The script consumes no build number, refuses a build
that does not exist (exit 3), is not `VALID` yet (exit 4) or a group that does
not exist (exit 5), reads the assignment back rather than trusting the 2xx
(exit 6), and treats "already in the group" as success so a tag pushed twice
is harmless. The first time, run it by hand against an internal group, where
a wrong result costs nothing:

```
ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=… Scripts/promote-build.sh 231 "Internal"
```

or dispatch the workflow with a build number and group. The version's Beta
App Review is already passed, so a build promoted under the current
`MARKETING_VERSION` reaches external testers without re-review; the first
build of a *new* version string re-enters review, which is the cost of a
version cut, not a defect.

Build numbers below 276 have gaps: in the nightly era a declined night still
consumed a `run_number`. Since builds became the newest tag plus one, a run
that fails before its upload leaves no gap and one that fails after it leaves
one. A missing number is not a lost release; check the Actions run list before
assuming one went wrong.

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
      when App Store Connect holds a number no `build-*` tag records (an
      upload made outside CI). A CI upload that landed but was not tagged is
      fixed by pushing its tag by hand, not by overriding — see "Manual
      dispatch" above.
- [ ] The build number is derived automatically as the newest `build-*` tag
      plus one (`200 + run_number` only for a repository with no tag at all);
      there is nothing to bump in `App/project.yml` any more. It is validated
      (numeric, above the consumed 1–6, and above the newest tag, override
      included) *before* the build starts, and the number used is written to
      the run summary.
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
| The App Store CI profile (exact portal name in `App/ExportOptions-ci.plist`) | `PROVISIONING_PROFILE_BASE64` | **Manually managed.** Xcode refuses an Xcode-managed profile under manual signing, so this cannot be the "iOS Team Store Provisioning Profile" Xcode maintains. The profile still carries the old wordmark spelling in Apple's portal; rename it there first, at the next regeneration. |
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
- [ ] Tester feedback needs no pulling: `testflight-feedback.yml` posts new
      TestFlight screenshot and crash submissions to the pinned digest issue
      #299 daily, once each (`Scripts/testflight-feedback-digest.sh`). Run
      `Scripts/fetch-testflight-feedback.sh --download DIR` for a listed
      submission's screenshots and crash log.

## 3. Version page

The per-version text — description, What's New, promotional text, keywords,
App Review notes — lives in `docs/app-store/listing/` and is written by the
**App Store listing** workflow, which can also select the build. Dry run
first: it prints a diff of App Store Connect against the repo and changes
nothing. Then apply, from `main`:

```sh
gh workflow run app-store-listing.yml --ref main -f build=<N>
gh workflow run app-store-listing.yml --ref main -f build=<N> -f apply=true
```

A version that does not exist yet on App Store Connect is created by the
same workflow with `-f create=true`: the version, its en-US localization and
its App Review detail with the reviewer contact copied from the newest
existing version. The dry run only says what it would create; with
`apply=true` it creates and then writes the listing in the same run.

- [ ] **Listing text + build:** the two runs above. Update
      `listing/whats-new.txt` for the release first.

- [ ] **Name / Subtitle:** §1–2 ("Waddle: WAD Player" / "Play classic
      Doom WADs")
- [ ] **Support URL:** https://github.com/tylervick/waddle
- [ ] **Privacy Policy URL:**
      https://github.com/tylervick/waddle/blob/main/PRIVACY.md
   (verify this URL resolves (HTTP 200) after PR #4 merges to main, before entering it in App Store Connect)
- [ ] **Category:** Games → Action (§7)
- [ ] **Copyright:** `© 2026 Tyler Vick; engine GPL-2.0` (§10)
- [ ] **Screenshots:** run the **App Store screenshots** workflow, which
      replaces both sets (6.9" iPhone, 13" iPad, six each) with
      `docs/app-store/screenshots/` in the slot order of §12. Dry run first —
      it changes nothing and proves no target set is shared with the live
      listing — then again with `apply`, from `main`:

      ```sh
      gh workflow run app-store-screenshots.yml --ref main
      gh workflow run app-store-screenshots.yml --ref main -f apply=true
      ```

      It deletes each set's old shots before uploading (a set holds at most
      10), verifies every upload landed landscape, and pins the slot order.
      Locally, `Scripts/upload-screenshots.sh [--apply]` does the same with
      `ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_KEY_PATH` set.

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

- [ ] App Review notes: written with the listing in §3, from
      `listing/review-notes.txt` (GPL source port, only Freedoom bundled, no
      network, demo path: tap "Freedoom Phase 1"). Reasoning: metadata.md §11.
- [ ] **GPL posture check (must all be true before tapping Submit):**
  - Repo is public and the complete corresponding source for the
    submitted build is on `main` (the About screen links to it).
  - `COPYING` (GPL-2.0) at the repo root; Freedoom's BSD license ships in
    the app bundle (`GameData/FREEDOOM-COPYING.txt`) and the About screen
    surfaces all licenses.
  - No copyrighted commercial game content in the repo or the bundle —
    Freedoom only.
  - **Licence agreement is Apple's standard EULA, by decision** — both
    `betaLicenseAgreement.agreementText` and the `endUserLicenseAgreement`
    relationship are deliberately empty. Confirm they are still empty with
    the `curl` check in `metadata.md` §14; a non-empty value means someone
    set a custom agreement without updating that section. This bullet exists
    because the EULA is the one GPL question this gate used to omit, and an
    empty field left by decision has to be distinguishable from one nobody
    got to. Basis, comparables, and the accepted residual risk: §14.
- [ ] Submit for review — the **App Store submit** workflow. Dry run first:
      it re-reads the build, the content-rights answer, both licence fields
      (the §14 check above, scripted) and whether an open submission already
      exists, and prints what it would submit. Then apply:

      ```sh
      gh workflow run app-store-submit.yml --ref main
      gh workflow run app-store-submit.yml --ref main -f apply=true
      ```

      It creates the review submission, adds the version, marks it submitted,
      and reads the state back (`WAITING_FOR_REVIEW`). What it cannot check
      stays above: the corresponding source on `main`, and App Privacy.

## Known limitations (for the record, no action needed)

- A corrupted app container at cold start hits a `fatalError` rather than
  a recovery flow (container-init recovery needs design; risk is
  cold-start-only). Documented as a carried item in the Plan 4 review
  notes.
- Corrupt-entry-only zips inside an otherwise-valid archive import the
  valid entries and quarantine the rest to `Documents/Import Failed/` —
  documented behavior, not a bug.
