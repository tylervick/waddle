# TestFlight CI Workflow — Design Spec

**Date:** 2026-07-29
**Status:** Implemented in PRs #20–#24 (2026-07-30). First CI release: build 205.
**Branch:** `tylervick/testflight-ci`
**Predecessor:** PR #11 (`docs/superpowers/specs/2026-07-28-ci-build-scripts-design.md`)

## Problem

PR #11 added build and test CI. Releases are still driven by hand from a
developer machine: `Scripts/archive.sh` then `Scripts/upload.sh`, with the
build number bumped manually in `App/project.yml`.

That has already gone wrong twice. Build 5's bump was never committed, so
`main` claimed 4 while TestFlight held 5; PR #10 landed the catch-up. Build 6
needed its own PR (#12) to keep the two in step. The failure is structural,
not careless — a number that must be incremented by hand before every release
will drift.

This spec covers a `workflow_dispatch` workflow that archives, signs, and
uploads to TestFlight from CI, reusing the composite action and release
scripts that already exist.

## Scope

**In:** `.github/workflows/testflight.yml`; a `skip-cache` input on
`.github/actions/setup-waddle-build`; changes to `Scripts/archive.sh`; a
CI-specific export options plist; SHA-pinning of the actions the release path
executes; moving `inputs.xcode-version` out of a `run:` body into `env:`.

**Out:** the broader Renovate/dependency-automation story (#16 — another
change owns `renovate.json`), the scheduled cold-cache build (#14), the
README CI section (#15), and `Scripts/build-deps.sh`'s re-fetch bug (#13).

**Out, deliberately:** App Store *submission*. This ships to TestFlight only.

## Research basis

The first draft of this design was reviewed against the wider ecosystem and
adversarially attacked before being written down. That surfaced defects the
design would otherwise have shipped, and several are the reason particular
choices below look the way they do. Findings that changed the design are
cited inline rather than collected in an appendix, so the reasoning sits next
to the decision it justifies.

## Signing: manual, with a pre-installed profile

**Decision:** install a provisioning profile from a secret, sign with
`signingStyle: manual`, and never let `xcodebuild` invoke the
provisioning-update path that can mint a certificate. `xcodebuild` *is*
authenticated against the developer portal via the API key -- that
authentication is not what's withheld. Manual signing is what limits it: with
a pre-installed profile there is nothing to update, so `xcodebuild` has no
occasion to reach for portal write operations, only (at most) a profile
download.

The rejected alternative was `signingStyle: automatic` plus
`-allowProvisioningUpdates`, which is what `archive.sh` uses locally today.
On CI that combination is actively dangerous: when the signing identity is
not found, `xcodebuild` does not fail — it **mints a new Apple Distribution
certificate**, whose private key then dies with the ephemeral runner. Apple
caps distribution certificates at 2–3 per account. A handful of failed runs
exhausts the cap, and the only repair is manual revocation in the Developer
portal. It is the sole failure mode in this design with irreversible,
off-repository consequences.

Independently, `-allowProvisioningUpdates` is unreliable enough on hosted
runners that Kiwix wraps it in a five-attempt retry loop, and several
comparable projects (UTM, Bitwarden) avoid it entirely by pre-installing a
profile. Manual signing removes both the hazard and the flakiness.

The profile already exists and does not need generating:
`iOS Team Store Provisioning Profile: com.tylervick.waddle`,
`352UZEKYPP.com.tylervick.waddle`, no `ProvisionedDevices` key (confirming
distribution rather than development or ad-hoc).

### The keychain steps, in full

The ephemeral keychain is built with `security` directly rather than a
marketplace action. Four of these five steps are load-bearing in ways that
fail confusingly when omitted:

```bash
security create-keychain -p "$KC_PW" "$KC"
security set-keychain-settings -lut 21600 "$KC"          # no auto-lock mid-build
security unlock-keychain -p "$KC_PW" "$KC"
security import cert.p12 -k "$KC" -P "$P12_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$KC_PW" "$KC"
```

- **`list-keychains`** is not optional. Without adding the new keychain to the
  search list, `codesign` and `xcodebuild` never look inside it and the
  archive fails with `No signing certificate "Apple Distribution" found`.
  Two independent reviews flagged this as missing from the first draft.
- **`set-key-partition-list` must include `codesign:`**, not just
  `apple-tool:,apple:`. The shorter form circulates widely in older guides
  and is insufficient. Its failure mode is the worst kind: macOS queues a GUI
  authorization prompt that never arrives on a headless runner, so the job
  **hangs silently until the timeout kills it** rather than reporting an
  error.
- **Appending to the existing search list** rather than replacing it. Note
  that `security list-keychains -s` *replaces* by default. This matters less
  on an ephemeral runner than on a developer machine, but anyone running
  these commands locally to debug the workflow would otherwise drop
  `login.keychain` from their search list and break Xcode, git credentials
  and Safari passwords until they restored it. The command above appends.

The keychain is deleted in an `if: always()` step. On a GitHub-hosted runner
this is close to cosmetic — the VM is destroyed regardless — but it is the
behaviour that stays correct if the workflow is ever moved to a self-hosted
runner.

## Build number: run number plus a fixed offset

**Decision:** `CI_BUILD_NUMBER = 200 + github.run_number`, overridable by a
`build_number` dispatch input, validated before the archive starts.

Commit count (`git rev-list --count HEAD`) was the original choice and is
wrong here, for two confirmed reasons:

1. **`actions/checkout@v4` defaults to `fetch-depth: 1`.** On a shallow
   clone `git rev-list --count HEAD` returns **1**, not 163 — verified
   directly. Build 1 is already consumed, so the first dispatch would have
   spent roughly nine minutes archiving and signing before dying at
   `ITMS-4238: Redundant Binary Upload`.
2. **It is not monotonic across refs.** A topic branch that forked at commit
   140 and added five commits yields 145, below `main`'s 163. Under
   squash-merge the two counts grow at unrelated rates. App Store Connect
   hard-rejects a non-increasing build number for a given version. Mastodon's
   iOS client uses commit count only as one of three candidates, taking
   `[testflight_latest + 1, appstore_latest + 1, git_count].max` — treating
   it as a floor, never a source of truth.

`github.run_number` is monotonic by construction, independent of clone depth
and of which ref is dispatched. The `200` offset is a one-time floor chosen
to clear the consumed 1–6 with room for any out-of-band manual uploads; it is
recorded here so it is a documented constant rather than an unexplained
number in a YAML file. `run_number` starts at 1 for a newly added workflow,
so **the first CI release is build 201**.

**Re-runs reuse `run_number`**, which is precisely what the `build_number`
override input exists for.

A guard runs **before** the archive, so a bad value costs seconds rather than
a full build:

```bash
[[ "$N" =~ ^[0-9]+$ ]] || { echo "::error::build number '$N' is not numeric"; exit 1; }
(( N > 6 )) || { echo "::error::build number $N is at or below consumed builds"; exit 1; }
```

The mechanism itself is sound and was verified: XcodeGen writes the literal
`$(CURRENT_PROJECT_VERSION)` into `App/Info.plist` at generate time,
`xcodebuild` expands build-setting references during Process Info.plist, and
a command-line override beats the target's `base` setting. `archive.sh`
re-running `xcodegen generate` does not clobber it, because the value never
passes through `project.yml`.

**Known limitation, deliberately not solved here:** `MARKETING_VERSION` stays
pinned at `1.0`, so every TestFlight build is `1.0 (N)`. Once 1.0 ships to
the App Store, releases will need a marketing-version bump in `project.yml`
before this workflow can produce an acceptable build. That is a release-process
decision, not something CI should guess at.

## Releases rebuild the engine from source

**Decision:** `testflight.yml` passes a new `skip-cache: true` input to
`setup-waddle-build`, which bypasses both cache restores and builds SDL,
OpenAL and Woof from source.

The cross-ref cache-poisoning attack that motivated the question turns out
not to exist: GitHub scopes caches created by a pull request to the merge ref,
and runs cannot restore caches from sibling or child branches. There are no
`restore-keys` here, so there is no near-miss substitution either.

The real reason is weaker but sufficient. `check-engine-fresh.sh` compares
the framework against a fingerprint stamp that lives **inside the same cache
entry**, so any entry carrying a matching stamp passes trivially. It is a
staleness guard, not an integrity guard — it was designed to catch "I forgot
to rebuild", not to attest a binary. Using it that way would mean shipping
whatever blob sat under a cache key, never rebuilt from the tree.

Secondary benefit: `workflow_dispatch` is on GitHub's list of triggers
permitted to write default-branch caches, so a cache-using `testflight.yml`
would become the writer of `main`'s engine cache and every subsequent PR
would inherit the release job's engine. Skipping the cache avoids that
coupling.

Cost is roughly 25 minutes on a workflow run a handful of times, which buys a
shipped binary reproducible from its source tree.

## `Scripts/archive.sh`: extended, not duplicated

`archive.sh` gains optional behaviour driven entirely by environment
variables, so one archive path serves both a developer machine and CI. With
no environment set its `xcodebuild` command lines are unchanged.

- ASC auth flags (`-authenticationKeyPath`, `-authenticationKeyID`,
  `-authenticationKeyIssuerID`) are appended when all three of
  `ASC_KEY_PATH`, `ASC_KEY_ID`, `ASC_ISSUER_ID` are set. `ASC_KEY_PATH` is
  not a secret — it is the runtime path where the workflow decoded
  `ASC_PRIVATE_KEY`, under `$RUNNER_TEMP`.
- `CURRENT_PROJECT_VERSION=$N` is appended when `BUILD_NUMBER` is set.
- `EXPORT_OPTIONS_PLIST` overrides the export options path, defaulting to
  today's `App/ExportOptions.plist`.
- `-allowProvisioningUpdates` stays exactly where it is — already hardcoded
  on the export line — and is **not** added to the archive step. With a
  pre-installed profile and manual signing there is nothing to update, and
  adding it is what enables certificate minting.

### The bash 3.2 trap

macOS ships `/bin/bash` 3.2.57, which `archive.sh`'s shebang selects. Under
`set -u`, bash 3.2 treats `"${ARR[@]}"` on an **empty** array as an unbound
variable and aborts:

```
./t.sh: line 5: ARGS[@]: unbound variable
exit=1
```

The obvious implementation — build an array, append conditionally, expand
into both `xcodebuild` calls — therefore breaks `archive.sh` in exactly the
"no environment set" case this section claims is unchanged. CI would never
catch it, because CI always sets the environment; the regression would land
only on developer machines, in the release script.

Every conditional array must use the guarded expansion
`"${ARGS[@]+"${ARGS[@]}"}"`, and this must be **tested**, not asserted.
`Scripts/test-release-args.sh` will run the argument assembly under
`/bin/bash` with no environment set, following the hermetic-test pattern
already established by `test-engine-fingerprint.sh` and
`test-check-engine-fresh.sh`.

## Upload: keep `altool`, but verify it

`Scripts/upload.sh` already reads `ASC_KEY_ID` and `ASC_ISSUER_ID` from the
environment and supports `--validate`, so its interface needs no change. It
does need two additions, both env-driven and inert when unset, following the
same pattern as `archive.sh`:

- When `ASC_KEY_PATH` is set, pass `--p8-file-path "$ASC_KEY_PATH"` instead of
  relying on `altool`'s implicit key search. See the secrets section for why
  the implicit search is undesirable.
- Capture `altool` output and inspect it, rather than trusting the exit code
  (see below). Unset, behaviour is exactly as today.

Two facts about `altool` are recorded here so the choice is informed rather
than accidental:

1. `altool`'s own usage text marks `--upload-app` as
   `[DEPRECATED use --upload-package instead]`. It still works. Apple's
   notarization deprecation (TN3147, `notarytool`) is a *separate* matter and
   does not apply to App Store uploads — these are commonly conflated.
   `--upload-package` is not a drop-in: it requires `--asc-public-id`,
   `--apple-id`, `--bundle-version`, `--bundle-short-version-string`,
   `--bundle-id` and `--type`.
2. **More seriously, Xcode 26's `altool` can report success on a failed
   upload.** A genuinely failed upload — a duplicate bundle version, visible
   only in verbose output — has been observed reported as
   `"Successfully uploaded the new binary to App Store Connect"`. This
   project builds with Xcode 26.2, so a green run does not by itself prove a
   build reached App Store Connect.

**Mitigation:** `upload.sh` captures `altool` output, greps it for known error
markers (`ERROR ITMS-`, `error:`) and exits non-zero if any are present, rather
than trusting the exit code alone. The run summary states the build number and
instructs the reader to confirm the build appears in App Store Connect. This is
honest about the limitation rather than papering over it — output inspection
narrows the window, it does not close it.

`xcodebuild -exportArchive` with `destination: upload` in the export options
would remove `altool` from the picture entirely, and was evaluated. Whether
it honours API-key authentication headlessly is genuinely disputed — Xcode 15
release notes claim support, a 2024 Developer Forums thread shows it failing
with that exact flag combination, and an open radar (FB9145847) requests it.
Not adopted without evidence; recorded as a future option.

## Secrets

Six, all already configured on the repository:

| Secret | Contents |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Apple Distribution `.p12`, base64 |
| `P12_PASSWORD` | password for that `.p12` |
| `PROVISIONING_PROFILE_BASE64` | App Store `.mobileprovision`, base64 |
| `ASC_KEY_ID` | App Store Connect key id |
| `ASC_ISSUER_ID` | App Store Connect issuer id |
| `ASC_PRIVATE_KEY` | ASC `.p8`, base64 |

### Why the `.p8` is stored base64

GitHub's documentation is explicit that structured data breaks secret
redaction, because masking relies on an exact match, and that multi-line
values are processed line by line and never match. A raw `.p8` is multi-line
PEM — stored directly, it would be **effectively unmasked in logs**. Base64
makes it a single line and therefore actually maskable.

Handling rules that follow from that:

- Decode with `printf '%s'`, never `echo`, never a heredoc.
- Write under `umask 077` into `"$RUNNER_TEMP"`, not `$HOME`.
- **Never enable `set -x` in any step touching it.**
- Pass it to `altool` via `--p8-file-path` rather than relying on the
  implicit `~/.appstoreconnect/private_keys` search, which also removes the
  ambiguity of `altool` searching `./private_keys` (relative to the checkout)
  first.

### Not leaks, recorded so they are not re-investigated

The `.ipa` artifact is publicly downloadable on a public repo but contains no
private key — `embedded.mobileprovision` holds the public certificate and
team id, present in every shipped App Store app.
`BUILD_CERTIFICATE_BASE64` decodes to binary and cannot realistically appear
in a text log. `CURRENT_PROJECT_VERSION=N` does appear in `xcodebuild`'s
`Build settings from command line:` block — harmless, and a reason never to
route an ASC value through a build setting.

### Expiry — dated, because the failure is opaque

- **Distribution certificate expires 2027-05-02.** Regenerate
  `BUILD_CERTIFICATE_BASE64` and `P12_PASSWORD`.
- **Provisioning profile expires 2027-07-20.** Regenerate
  `PROVISIONING_PROFILE_BASE64`.

The certificate lapses first. Neither failure announces itself as an expiry;
both present as opaque signing errors.

## Workflow shape

`workflow_dispatch` only. Uploading to TestFlight is a deliberate act and
should never be a side effect of a push or a tag.

Inputs: `validate_only` (boolean, default false) and `build_number` (string,
blank derives).

```yaml
concurrency:
  group: testflight          # ref-INDEPENDENT: two dispatches on different
  cancel-in-progress: false  # refs must still serialize, and cancelling
                             # mid-upload burns a build number server-side
permissions:
  contents: read
timeout-minutes: 90
```

The `concurrency` group deliberately does **not** follow `ci.yml`'s
`ci-${{ github.ref }}` pattern: a ref-keyed group would not serialize two
dispatches on different refs, which is the exact race it exists to prevent.

Steps:

1. `actions/checkout`
2. Validate the build number (fails in seconds, before any build)
3. `setup-waddle-build` with `skip-cache: true`
4. Install signing assets: ephemeral keychain, provisioning profile, `.p8`
5. `Scripts/archive.sh`
6. **Upload the `.ipa` artifact** — before the upload step, so a failed
   upload does not discard a ~25-minute build
7. `Scripts/upload.sh` (with `--validate` when `validate_only`), with output
   verification
8. Write the build number to `$GITHUB_STEP_SUMMARY` unconditionally
9. Delete the keychain — `if: always()`

The `.ipa` artifact uses `retention-days: 7`, matching `ci.yml`; a signed App
Store build should not sit publicly downloadable for the 90-day default. The
distribution-logs artifact uses `retention-days: 3` instead -- shorter
because, unlike the `.ipa`, its contents can include the ASC key id and
account emails, and artifact contents are not covered by GitHub's secret
masking on a public repo.

## Supply chain

The release job holds all six secrets, and the composite action it calls
pulls `jdx/mise-action@v2` — a third-party action at a floating major tag.
Hand-rolling `security` commands on trust grounds while executing a floating
third-party tag in the same job does not add up, and this was a real
inconsistency in the first draft.

Every action the release path executes is SHA-pinned with a trailing
`# vX.Y.Z` comment: `jdx/mise-action`, plus `actions/checkout`,
`actions/cache` and `actions/upload-artifact` as used by `testflight.yml` and
`setup-waddle-build`. Broader pinning and the automation that keeps pins
current belong to #16.

`inputs.xcode-version` also moves out of a `run:` body into `env:` in the
composite action. It is inert today — it only ever receives a literal — but
it becomes a live injection vector the moment a dispatch input feeds it, and
this is the change that starts calling that action from a workflow with
dispatch inputs.

## Failure modes

| Situation | Behaviour |
|---|---|
| Bad `build_number` input | Rejected in seconds, before the build |
| Archive fails | `.xcdistributionlogs` are the only diagnostic; captured `if: failure()` with 3-day retention. They can contain the ASC key id and account emails, so they are **not** uploaded on success |
| Archive succeeds, upload fails | `.ipa` already uploaded as an artifact; re-dispatch with `build_number` override |
| Upload succeeds, job cancelled | Build number is burned server-side. The step summary records the number even on failure, so it is recoverable from the run |
| Two dispatches race | Serialized by the ref-independent concurrency group |
| Keychain cleanup skipped | Cosmetic on a hosted runner (VM destroyed); would matter on self-hosted |

## Verification

Locally testable, and required before the PR opens:

- `Scripts/test-release-args.sh` — argument assembly under `/bin/bash` with
  no environment set produces a command line byte-identical to today's, and
  does not abort on the empty array.
- The same test with ASC and `BUILD_NUMBER` set produces exactly the expected
  additional flags, correctly quoted.
- `Scripts/test-engine-fingerprint.sh` and
  `Scripts/test-check-engine-fresh.sh` still pass.
- `actionlint` clean.

Only verifiable on CI:

- **First dispatch must be `validate_only: true`.** That exercises the
  keychain, profile installation, manual signing, archive and export — the
  entire pipeline except the irreversible step — without consuming a build
  number. If signing is going to fail, it fails there for free.
- A subsequent real dispatch confirms upload and App Store Connect
  processing.

## Documentation debt this creates

`docs/app-store/submission-checklist.md` §1 still states that export fails
with `No profiles for 'com.tylervick.waddle' were found` and calls that "the
current state", and §2 documents Xcode Organizer or manual Transporter as the
upload path. Builds 1–6 have shipped since. Landing this workflow without
updating that document leaves two contradictory procedures, and it is the
document someone will read during a failed release at an unsociable hour. It
is updated as part of this change.

## Risks

- **`altool` may report success on a genuinely failed upload** (Xcode 26).
  Mitigated by output inspection, not eliminated. The definitive check
  remains App Store Connect itself.
- **A ~25-minute release build** is a deliberate trade for reproducibility.
  If it becomes painful, the honest fix is #14's cold-cache build proving the
  cached path, not silently reintroducing the cache here.
- **`MARKETING_VERSION` pinned at 1.0** will eventually block releases and
  requires a human decision when it does.
- **Runner-image regressions in keychain handling recur.** A `macos-26` image
  update has previously broken `.p12` import in a way that reported success
  but left `codesign` unable to find the identity. This affects raw commands
  and marketplace actions equally, since both call the same `security`
  binary. No mitigation beyond awareness and the `validate_only` dry run.
