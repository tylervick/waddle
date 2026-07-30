# TestFlight CI Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a manually-dispatched GitHub Actions workflow that archives, signs, and uploads a build to TestFlight, replacing a hand-driven release that has already drifted its build number twice.

**Architecture:** `testflight.yml` reuses the existing `setup-waddle-build` composite action (with a new `skip-cache` input so releases rebuild the engine from source), then signs with a certificate and provisioning profile installed from secrets into an ephemeral keychain. `Scripts/archive.sh` and `Scripts/upload.sh` gain env-driven behaviour so one release path serves both a developer machine and CI.

**Tech Stack:** GitHub Actions (`macos-26`), `xcodebuild`, `xcrun altool`, `security`, bash 3.2.

**Spec:** `docs/superpowers/specs/2026-07-29-testflight-ci-design.md`

## Global Constraints

- Runner `macos-26`; Xcode pinned to **26.2**; `timeout-minutes: 90`; `permissions: contents: read`.
- **Signing is MANUAL.** `-allowProvisioningUpdates` must NOT be added to the archive step. With automatic signing it can mint a new Apple Distribution certificate on failure; Apple caps those at 2–3 and cleanup is manual portal revocation. This is the only irreversible failure mode in the design.
- Build number = `200 + github.run_number`, overridable by the `build_number` input. **First CI release is build 201.** Builds 1–6 are consumed.
- **Never `set -x` in any step touching `ASC_PRIVATE_KEY`.** A decoded `.p8` is multi-line PEM; GitHub's secret masking requires a single-line exact match and will not redact it.
- macOS `/bin/bash` is **3.2.57**. Under `set -u`, `"${ARR[@]}"` on an empty array aborts the script. Every conditional array expansion must use `"${ARR[@]+"${ARR[@]}"}"`.
- Scripts must behave **identically to today** when the new env vars are unset. This is tested, not asserted.
- Commit messages must contain no Co-Authored-By line and no mention of Claude, AI, or any assistant.
- Do NOT modify `renovate.json` — another change owns that file.
- Out of scope: broader SHA pinning/Renovate (#16), cold-cache build (#14), README CI section (#15), `build-deps.sh` re-fetch bug (#13).

## Known values (use these exactly)

| Thing | Value |
|---|---|
| Provisioning profile name | `iOS Team Store Provisioning Profile: com.tylervick.waddle` |
| Profile UUID | `a3d35c8f-ca0d-4569-8d70-ad380e21cde7` |
| Bundle id | `com.tylervick.waddle` |
| Team id | `352UZEKYPP` |
| Signing certificate | `Apple Distribution` |
| Cert expires | 2027-05-02 |
| Profile expires | 2027-07-20 |

Action SHAs — these pin the **currently used** major tags, preserving behaviour. Do NOT substitute the latest release (`checkout` is on v7, `cache` on v6, `mise-action` on v4); that would be a major-version upgrade disguised as a pin.

| Action | Pin |
|---|---|
| `jdx/mise-action` | `c37c93293d6b742fc901e1406b8f764f6fb19dac # v2` |
| `actions/checkout` | `11d5960a326750d5838078e36cf38b85af677262 # v4` |
| `actions/cache` | `0057852bfaa89a56745cba8c7296529d2fc39830 # v4` |
| `actions/upload-artifact` | `ea165f8d65b6e75b540449e92b4886f43607fa02 # v4` |

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `Scripts/archive.sh` | Modify | Gains optional ASC auth flags, build-number override, export-plist override, and a print-only mode |
| `Scripts/upload.sh` | Modify | Gains `--p8-file-path` support and `altool` output verification |
| `Scripts/test-release-args.sh` | Create | Hermetic tests that both scripts assemble correct command lines, including the empty-array case under bash 3.2 |
| `.github/actions/setup-waddle-build/action.yml` | Modify | New `skip-cache` input; `xcode-version` moved to `env:`; SHA-pinned actions |
| `App/ExportOptions-ci.plist` | Create | Manual signing with an explicit profile map |
| `.github/workflows/testflight.yml` | Create | The release workflow |
| `docs/app-store/submission-checklist.md` | Modify | Replace the stale manual procedure (Task 4, after verification) |

---

### Task 1: Env-driven release scripts, with tests

Both scripts gain behaviour that is inert unless specific env vars are set. The bash 3.2 empty-array trap makes "inert when unset" a real risk, not a formality, so this task is test-first.

**Files:**
- Modify: `Scripts/archive.sh`
- Modify: `Scripts/upload.sh`
- Test: `Scripts/test-release-args.sh` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces, for Task 3 to set:
  - `ASC_KEY_PATH`, `ASC_KEY_ID`, `ASC_ISSUER_ID` — all three must be set for `archive.sh` to add auth flags. `ASC_KEY_PATH` is a filesystem path, not a secret.
  - `BUILD_NUMBER` — integer; adds `CURRENT_PROJECT_VERSION=$N` to the archive step.
  - `EXPORT_OPTIONS_PLIST` — path, relative to repo root; defaults to `App/ExportOptions.plist`.
  - `ARCHIVE_PRINT_ONLY` — when `1`, `archive.sh` prints both `xcodebuild` command lines and exits 0 without building. Used only by the test.
  - `upload.sh` uses `ASC_KEY_PATH` for `--p8-file-path` when set.

- [ ] **Step 1: Write the failing test**

Create `Scripts/test-release-args.sh`:

```bash
#!/bin/bash
# Tests that Scripts/archive.sh and Scripts/upload.sh assemble correct
# command lines, and -- critically -- that they still work with NO new env
# vars set.
#
# Why this test exists: macOS /bin/bash is 3.2.57, where `set -u` treats
# "${ARR[@]}" on an EMPTY array as an unbound variable and aborts. The
# natural implementation (build an array, append conditionally, expand)
# therefore breaks the LOCAL release path -- the exact case the design
# claims is unchanged -- while CI, which always sets the env, never notices.
# The guarded expansion "${ARR[@]+"${ARR[@]}"}" is what makes it safe.
#
# archive.sh is invoked with ARCHIVE_PRINT_ONLY=1 so it prints its command
# lines and exits before doing any work. It cannot be stubbed via PATH: the
# export step deliberately runs `PATH="/usr/bin:$PATH" xcodebuild`, which
# would find the real binary ahead of any stub.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# Force bash 3.2 explicitly -- a newer bash on PATH would hide the bug.
BASH32=/bin/bash
"$BASH32" --version | head -1 | grep -q 'version 3\.2' \
  || echo "warn: $BASH32 is not 3.2; the empty-array case may not be exercised"

run_archive() { env -u ASC_KEY_PATH -u ASC_KEY_ID -u ASC_ISSUER_ID \
                    -u BUILD_NUMBER -u EXPORT_OPTIONS_PLIST \
                    ARCHIVE_PRINT_ONLY=1 "$@" "$BASH32" "$ROOT/Scripts/archive.sh"; }

# 1. THE REGRESSION GUARD. No new env set -> must not abort on the empty array.
OUT="$(run_archive 2>&1)" || fail "archive.sh aborted with no env set: $OUT"
pass "archive.sh survives with no new env set (bash 3.2 empty array)"

# 2. With nothing set, no auth flags and no version override leak in.
case "$OUT" in
  *-authenticationKey*) fail "auth flags present with no ASC env set" ;;
  *CURRENT_PROJECT_VERSION*) fail "version override present with no BUILD_NUMBER" ;;
esac
grep -q "App/ExportOptions.plist" <<<"$OUT" || fail "default export plist not used"
pass "no env -> no auth flags, no version override, default export plist"

# 3. All three ASC vars set -> auth flags on BOTH xcodebuild lines.
OUT3="$(ARCHIVE_PRINT_ONLY=1 ASC_KEY_PATH=/tmp/k.p8 ASC_KEY_ID=KEYID \
        ASC_ISSUER_ID=ISSUER "$BASH32" "$ROOT/Scripts/archive.sh" 2>&1)" \
  || fail "archive.sh failed with ASC env set"
[ "$(grep -c -- '-authenticationKeyPath /tmp/k.p8' <<<"$OUT3")" -eq 2 ] \
  || fail "expected auth flags on BOTH archive and export lines"
grep -q -- '-authenticationKeyID KEYID' <<<"$OUT3" || fail "missing key id"
grep -q -- '-authenticationKeyIssuerID ISSUER' <<<"$OUT3" || fail "missing issuer id"
pass "ASC env -> auth flags on both xcodebuild invocations"

# 4. Partial ASC env must NOT produce half-configured auth flags.
OUT4="$(ARCHIVE_PRINT_ONLY=1 ASC_KEY_ID=KEYID "$BASH32" "$ROOT/Scripts/archive.sh" 2>&1)" \
  || fail "archive.sh failed with partial ASC env"
case "$OUT4" in *-authenticationKey*) fail "auth flags added from partial env" ;; esac
pass "partial ASC env -> no auth flags"

# 5. BUILD_NUMBER -> version override on the ARCHIVE line only.
OUT5="$(ARCHIVE_PRINT_ONLY=1 BUILD_NUMBER=201 "$BASH32" "$ROOT/Scripts/archive.sh" 2>&1)" \
  || fail "archive.sh failed with BUILD_NUMBER set"
grep -q 'CURRENT_PROJECT_VERSION=201' <<<"$OUT5" || fail "version override missing"
[ "$(grep -c 'CURRENT_PROJECT_VERSION=201' <<<"$OUT5")" -eq 1 ] \
  || fail "version override should appear once (archive only), not on export"
pass "BUILD_NUMBER -> version override on the archive line only"

# 6. -allowProvisioningUpdates must be on export ONLY, never on archive.
#    On the archive step with automatic signing it can mint a distribution
#    certificate; Apple caps those at 2-3 and cleanup is manual revocation.
[ "$(grep -c -- '-allowProvisioningUpdates' <<<"$OUT3")" -eq 1 ] \
  || fail "-allowProvisioningUpdates must appear exactly once (export only)"
grep -q -- '-exportArchive.*-allowProvisioningUpdates\|-allowProvisioningUpdates.*-exportArchive' <<<"$OUT3" \
  || fail "-allowProvisioningUpdates is not on the export line"
pass "-allowProvisioningUpdates confined to the export step"

# 7. EXPORT_OPTIONS_PLIST override is honoured.
OUT7="$(ARCHIVE_PRINT_ONLY=1 EXPORT_OPTIONS_PLIST=App/ExportOptions-ci.plist \
        "$BASH32" "$ROOT/Scripts/archive.sh" 2>&1)" || fail "archive.sh failed with plist override"
grep -q 'App/ExportOptions-ci.plist' <<<"$OUT7" || fail "export plist override ignored"
pass "EXPORT_OPTIONS_PLIST override honoured"

# --- upload.sh ---------------------------------------------------------
# Stub xcrun so nothing is uploaded. upload.sh does NOT reset PATH, so a
# stub works here (unlike archive.sh's export step).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/xcrun" <<'STUB'
#!/bin/sh
echo "XCRUN_ARGS: $*"
STUB
chmod +x "$TMP/bin/xcrun"
: > "$TMP/fake.ipa"

run_upload() { env PATH="$TMP/bin:$PATH" ASC_KEY_ID=KEYID ASC_ISSUER_ID=ISSUER \
                   "$@" "$BASH32" "$ROOT/Scripts/upload.sh" "$TMP/fake.ipa"; }

# 8. No ASC_KEY_PATH -> no --p8-file-path (today's behaviour preserved).
#    `unset` inside the $( ) subshell, NOT `env -u`: run_upload is a shell
#    function, and env is an external binary that cannot see shell functions.
#    (`run_upload -u ASC_KEY_PATH` fails too -- run_upload forwards "$@" AFTER
#    its NAME=VALUE assignments, and BSD env requires options before them.)
U8="$(unset ASC_KEY_PATH; run_upload 2>&1)" || fail "upload.sh failed without ASC_KEY_PATH"
case "$U8" in *--p8-file-path*) fail "--p8-file-path present without ASC_KEY_PATH" ;; esac
pass "upload.sh unchanged when ASC_KEY_PATH unset"

# 9. ASC_KEY_PATH -> --p8-file-path passed through.
U9="$(run_upload ASC_KEY_PATH=/tmp/k.p8 2>&1)" || fail "upload.sh failed with ASC_KEY_PATH"
grep -q -- '--p8-file-path /tmp/k.p8' <<<"$U9" || fail "--p8-file-path not passed"
pass "upload.sh passes --p8-file-path when ASC_KEY_PATH is set"

# 10. THE XCODE 26 BUG. altool can print an ITMS error and still exit 0.
#     upload.sh must fail the run anyway.
cat > "$TMP/bin/xcrun" <<'STUB'
#!/bin/sh
echo "ERROR ITMS-4238: Redundant Binary Upload."
exit 0
STUB
chmod +x "$TMP/bin/xcrun"
if run_upload >"$TMP/u10" 2>&1; then
  fail "upload.sh reported success despite an ITMS error (Xcode 26 altool bug)"
fi
pass "upload.sh fails on an ITMS error even when altool exits 0"

echo "All release-arg tests passed."
```

Make it executable:

```bash
chmod +x Scripts/test-release-args.sh
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Scripts/test-release-args.sh`

Expected: FAIL at assertion 1 or 2 — `archive.sh` has no `ARCHIVE_PRINT_ONLY` mode yet, so it will attempt a real build (or fail the freshness guard) instead of printing.

- [ ] **Step 3: Rewrite `Scripts/archive.sh` lines 11-30**

Replace everything from line 11 (`"$ROOT/Scripts/check-engine-fresh.sh"`) to the end of the file with:

```bash
# Optional CI behaviour. All of this is inert when the env vars are unset,
# so a local `Scripts/archive.sh` produces exactly the command lines it
# always has. Scripts/test-release-args.sh proves that, because "inert when
# unset" is easy to get wrong here -- see the array note below.
#
# ASC_KEY_PATH/ASC_KEY_ID/ASC_ISSUER_ID : App Store Connect API key, needed
#   on a clean runner where no Xcode account is signed in. All three or none.
# BUILD_NUMBER  : overrides CURRENT_PROJECT_VERSION for this build only.
# EXPORT_OPTIONS_PLIST : defaults to App/ExportOptions.plist.
# ARCHIVE_PRINT_ONLY   : print the command lines and exit; used by the test.
#
# NOTE the "${ARR[@]+"${ARR[@]}"}" form below. macOS /bin/bash is 3.2.57,
# where `set -u` treats "${ARR[@]}" on an EMPTY array as an unbound variable
# and aborts the script. The plain form would break every local release
# while CI, which always sets these vars, stayed green.
ASC_ARGS=()
if [ -n "${ASC_KEY_PATH:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
    ASC_ARGS=(-authenticationKeyPath "$ASC_KEY_PATH"
              -authenticationKeyID "$ASC_KEY_ID"
              -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
VERSION_ARGS=()
if [ -n "${BUILD_NUMBER:-}" ]; then
    VERSION_ARGS=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
fi
EXPORT_PLIST="${EXPORT_OPTIONS_PLIST:-App/ExportOptions.plist}"
ARCHIVE="$ROOT/Vendor/archive/WADdle.xcarchive"

if [ "${ARCHIVE_PRINT_ONLY:-}" = "1" ]; then
    echo "ARCHIVE: xcodebuild -project App/WADdle.xcodeproj -scheme WADdle" \
         "-destination generic/platform=iOS -configuration Release" \
         "-archivePath $ARCHIVE" \
         "${ASC_ARGS[@]+"${ASC_ARGS[@]}"}" "${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"}" "archive"
    echo "EXPORT: xcodebuild -exportArchive -archivePath $ARCHIVE" \
         "-exportOptionsPlist $EXPORT_PLIST" \
         "-exportPath $ROOT/Vendor/archive/export" \
         "${ASC_ARGS[@]+"${ASC_ARGS[@]}"}" "-allowProvisioningUpdates"
    exit 0
fi

"$ROOT/Scripts/check-engine-fresh.sh"

cd "$ROOT/App" && xcodegen generate && cd "$ROOT"
# -allowProvisioningUpdates is deliberately NOT here. On the archive step
# with automatic signing it lets xcodebuild MINT a new distribution
# certificate when the identity is not found; Apple caps those at 2-3 per
# account and the only cleanup is manual revocation in the portal. CI signs
# manually with a pre-installed profile, so there is nothing to update.
xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
  -destination 'generic/platform=iOS' -configuration Release \
  -archivePath "$ARCHIVE" \
  "${ASC_ARGS[@]+"${ASC_ARGS[@]}"}" "${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"}" \
  archive
rm -rf "$ROOT/Vendor/archive/export"
# The export MUST use the system rsync (/usr/bin/rsync, openrsync). A Homebrew
# rsync 3.4.x earlier on PATH makes Xcode's IPA-copy step die with
#   rsync error: syntax or usage error (code 1) at main.c(1806)  ->  "Copy failed"
# so prepend /usr/bin. -allowProvisioningUpdates lets a first-time bundle id
# mint its distribution profile on the LOCAL path, which uses automatic
# signing; CI passes a manual-signing plist where it is a no-op.
PATH="/usr/bin:$PATH" xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$ROOT/Vendor/archive/export" \
  "${ASC_ARGS[@]+"${ASC_ARGS[@]}"}" \
  -allowProvisioningUpdates
echo "IPA at Vendor/archive/export/"
```

- [ ] **Step 4: Rewrite `Scripts/upload.sh` lines 25-27**

Replace the final two statements (the `echo` and the `xcrun altool` invocation) with:

```bash
# ASC_KEY_PATH (optional): pass the .p8 explicitly rather than relying on
# altool's implicit search of ./private_keys, ~/private_keys,
# ~/.private_keys and ~/.appstoreconnect/private_keys. The first of those is
# relative to the current directory, which is ambiguous in CI.
KEY_ARGS=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
    KEY_ARGS=(--p8-file-path "$ASC_KEY_PATH")
fi

echo "${ACTION#--} $IPA"
# Capture rather than stream: Xcode 26's altool has been observed printing an
# ITMS error and STILL exiting 0, reporting "Successfully uploaded" for an
# upload that did not happen. Trusting the exit code alone would make a
# failed release look green. See the design spec's upload section.
set +e
OUT="$(xcrun altool "$ACTION" -f "$IPA" -t ios \
        --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
        "${KEY_ARGS[@]+"${KEY_ARGS[@]}"}" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
if [ "$RC" -ne 0 ]; then
    echo "error: altool exited $RC" >&2
    exit "$RC"
fi
if printf '%s' "$OUT" | grep -qE 'ERROR ITMS-|error:'; then
    echo "error: altool reported an error but exited 0 (known Xcode 26 behaviour)." >&2
    echo "       treating this as a FAILED upload. Verify in App Store Connect." >&2
    exit 1
fi
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `Scripts/test-release-args.sh`

Expected: PASS — ten `ok - ...` lines, then `All release-arg tests passed.`

- [ ] **Step 6: Confirm the local path is genuinely unchanged**

```bash
bash -n Scripts/archive.sh && bash -n Scripts/upload.sh && echo "syntax OK"
ARCHIVE_PRINT_ONLY=1 /bin/bash Scripts/archive.sh
```

Expected: two lines, `ARCHIVE:` and `EXPORT:`, containing no `-authenticationKey`, no `CURRENT_PROJECT_VERSION`, and `App/ExportOptions.plist`. Do **not** run `Scripts/archive.sh` without `ARCHIVE_PRINT_ONLY` — it starts a full signed Release build.

- [ ] **Step 7: Commit**

```bash
git add Scripts/archive.sh Scripts/upload.sh Scripts/test-release-args.sh
git commit -m "feat(release): env-driven ASC auth, build number, and upload verification

archive.sh gains optional App Store Connect auth flags, a CURRENT_PROJECT_VERSION
override and an export-plist override; upload.sh gains --p8-file-path. All are
inert when unset, so the local release path is unchanged.

Guarded array expansion throughout: macOS /bin/bash 3.2 treats an empty array
under set -u as an unbound variable, which would have broken every local
release while CI stayed green. Covered by test-release-args.sh.

upload.sh now inspects altool output instead of trusting its exit code --
Xcode 26's altool can print an ITMS error and still exit 0."
```

---

### Task 2: Composite action — `skip-cache`, `env:` fix, SHA pins

**Files:**
- Modify: `.github/actions/setup-waddle-build/action.yml`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: a `skip-cache` input (string, default `'false'`). When `'true'`, both cache restores are skipped and both build scripts run unconditionally. Task 3 passes `skip-cache: 'true'`.

- [ ] **Step 1: Add the `skip-cache` input**

In `.github/actions/setup-waddle-build/action.yml`, extend the `inputs:` block (currently lines 6-9) to:

```yaml
inputs:
  xcode-version:
    description: Xcode version to select; must match a version on the runner image.
    required: true
  skip-cache:
    description: >-
      When 'true', ignore both caches and build SDL/OpenAL and the engine from
      source. Used by the release workflow so a shipped binary is reproducible
      from the tree rather than being whatever blob sat under a cache key.
      check-engine-fresh.sh cannot vouch for a restored framework: its
      fingerprint stamp lives inside the same cache entry, so any entry with a
      matching stamp passes trivially. It is a staleness guard, not an
      integrity guard.
    required: false
    default: 'false'
```

- [ ] **Step 2: Move `xcode-version` out of the `run:` body**

Replace the "Select Xcode" step (currently lines 14-24) with:

```yaml
    # XCODE_VERSION is passed via env rather than interpolated into the script
    # body. It only ever receives a literal today, but this action is about to
    # be called from a workflow that has dispatch inputs, and ${{ }} expansion
    # inside a run: block is a shell-injection vector the moment untrusted
    # input can reach it.
    - name: Select Xcode
      shell: bash
      env:
        XCODE_VERSION: ${{ inputs.xcode-version }}
      run: |
        APP="/Applications/Xcode_${XCODE_VERSION}.app"
        if [ ! -d "$APP" ]; then
          echo "::error::$APP not found on this runner image."
          echo "Installed Xcode versions:"
          ls -d /Applications/Xcode*.app
          exit 1
        fi
        sudo xcode-select -s "$APP"
        xcodebuild -version
```

- [ ] **Step 3: Gate the caches on `skip-cache` and pin the actions**

Change the `Install pinned CLI tools` step to the pinned SHA:

```yaml
    - name: Install pinned CLI tools
      uses: jdx/mise-action@c37c93293d6b742fc901e1406b8f764f6fb19dac # v2
```

Then add `skip-cache` to the `if:` on both cache steps and pin them. The engine cache step becomes:

```yaml
    - name: Restore engine framework
      id: engine-cache
      if: inputs.skip-cache != 'true'
      uses: actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830 # v4
```

and the deps cache step becomes:

```yaml
    - name: Restore SDL3 + OpenAL Soft
      id: deps-cache
      if: inputs.skip-cache != 'true' && steps.engine-cache.outputs.cache-hit != 'true'
      uses: actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830 # v4
```

Leave the `path:` and `key:` blocks of both steps exactly as they are.

- [ ] **Step 4: Make the build steps run when the cache is skipped**

A skipped `actions/cache` step leaves `steps.<id>.outputs.cache-hit` empty, so the existing `!= 'true'` conditions already evaluate true. That is correct but accidental — make it explicit so a future reader does not "simplify" it away:

```yaml
    # With skip-cache the restore steps do not run, so cache-hit is empty and
    # these conditions hold. Stated explicitly rather than relying on that.
    - name: Build SDL3 + OpenAL Soft
      if: inputs.skip-cache == 'true' || (steps.engine-cache.outputs.cache-hit != 'true' && steps.deps-cache.outputs.cache-hit != 'true')
      shell: bash
      run: Scripts/build-deps.sh

    - name: Build engine framework
      if: inputs.skip-cache == 'true' || steps.engine-cache.outputs.cache-hit != 'true'
      shell: bash
      run: Scripts/build-engine.sh
```

- [ ] **Step 5: Lint**

```bash
actionlint
```

Expected: no output, exit 0.

- [ ] **Step 6: Verify the existing workflows still parse and are unaffected**

```bash
git diff --stat
grep -n "skip-cache\|XCODE_VERSION\|mise-action@" .github/actions/setup-waddle-build/action.yml
```

Expected: only `action.yml` changed. `ci.yml` and `ui-tests.yml` do not pass `skip-cache`, so they get the `'false'` default and behave exactly as before.

- [ ] **Step 7: Commit**

```bash
git add .github/actions/setup-waddle-build/action.yml
git commit -m "feat(ci): add skip-cache input, harden xcode-version, pin actions

skip-cache lets the release workflow rebuild the engine from source. A
restored framework cannot be vouched for: check-engine-fresh.sh compares it
against a stamp stored in the same cache entry, so it is a staleness guard,
not an integrity guard.

xcode-version now reaches the script via env rather than \${{ }} interpolation,
ahead of this action being called from a workflow with dispatch inputs.

mise-action and cache are pinned to the commits their current major tags
resolve to -- preserving behaviour, not upgrading. Broader pinning is #16."
```

---

### Task 3: CI export options and the release workflow

**Files:**
- Create: `App/ExportOptions-ci.plist`
- Create: `.github/workflows/testflight.yml`

**Interfaces:**
- Consumes: `ASC_KEY_PATH`/`ASC_KEY_ID`/`ASC_ISSUER_ID`/`BUILD_NUMBER`/`EXPORT_OPTIONS_PLIST` from Task 1; `skip-cache` from Task 2.
- Produces: nothing later tasks consume.

- [ ] **Step 1: Create the CI export options**

Create `App/ExportOptions-ci.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- CI-only. App/ExportOptions.plist stays automatic for local use.
         Manual signing here is a safety property, not a preference: with
         automatic signing plus -allowProvisioningUpdates, a failure to find
         the identity makes xcodebuild MINT a new Apple Distribution
         certificate whose key dies with the runner. Apple caps those at 2-3
         and the only cleanup is manual revocation in the portal. -->
    <key>method</key><string>app-store-connect</string>
    <key>teamID</key><string>352UZEKYPP</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Apple Distribution</string>
    <key>provisioningProfiles</key>
    <dict>
        <!-- Installed from the PROVISIONING_PROFILE_BASE64 secret.
             Expires 2027-07-20; regenerate the secret before then. The
             failure mode on expiry is an opaque signing error. -->
        <key>com.tylervick.waddle</key>
        <string>iOS Team Store Provisioning Profile: com.tylervick.waddle</string>
    </dict>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
```

- [ ] **Step 2: Create the workflow**

Create `.github/workflows/testflight.yml`:

```yaml
name: TestFlight

# Manual dispatch only. Shipping to TestFlight is a deliberate act and must
# never be a side effect of a push or a tag.
on:
  workflow_dispatch:
    inputs:
      validate_only:
        description: Validate the build without uploading (does not consume a build number)
        type: boolean
        required: false
        default: false
      build_number:
        description: Override the derived build number (use when retrying a release)
        type: string
        required: false
        default: ''

# Ref-INDEPENDENT on purpose: a ref-keyed group (as ci.yml uses) would not
# serialize two dispatches on different refs, which is the exact race this
# prevents. cancel-in-progress is false because cancelling mid-upload burns a
# build number server-side while reporting nothing.
concurrency:
  group: testflight
  cancel-in-progress: false

permissions:
  contents: read

env:
  XCODE_VERSION: "26.2"
  # Builds 1-6 are consumed. run_number starts at 1 for a new workflow, so
  # this floor clears them with room for out-of-band manual uploads. First CI
  # release is 201. Documented in the design spec.
  BUILD_NUMBER_OFFSET: 200

jobs:
  testflight:
    name: Archive and upload
    runs-on: macos-26
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4

      # Fails in seconds. Without it a bad value costs a ~25 minute build
      # before App Store Connect rejects it.
      - name: Resolve and validate the build number
        id: buildnum
        env:
          OVERRIDE: ${{ inputs.build_number }}
          OFFSET: ${{ env.BUILD_NUMBER_OFFSET }}
          RUN_NUMBER: ${{ github.run_number }}
        run: |
          if [ -n "$OVERRIDE" ]; then N="$OVERRIDE"; else N=$(( OFFSET + RUN_NUMBER )); fi
          [[ "$N" =~ ^[0-9]+$ ]] || { echo "::error::build number '$N' is not numeric"; exit 1; }
          [ "$N" -gt 6 ] || { echo "::error::build number $N is at or below the consumed 1-6"; exit 1; }
          echo "value=$N" >> "$GITHUB_OUTPUT"
          echo "Build number: $N"

      - uses: ./.github/actions/setup-waddle-build
        with:
          xcode-version: ${{ env.XCODE_VERSION }}
          # Rebuild from source: a cached framework cannot be vouched for.
          skip-cache: 'true'

      # No set -x anywhere in this step. A decoded .p8 is multi-line PEM and
      # GitHub's masking needs a single-line exact match, so it would NOT be
      # redacted if it reached the log.
      - name: Install signing assets
        env:
          BUILD_CERTIFICATE_BASE64: ${{ secrets.BUILD_CERTIFICATE_BASE64 }}
          P12_PASSWORD: ${{ secrets.P12_PASSWORD }}
          PROVISIONING_PROFILE_BASE64: ${{ secrets.PROVISIONING_PROFILE_BASE64 }}
          ASC_PRIVATE_KEY: ${{ secrets.ASC_PRIVATE_KEY }}
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
        run: |
          umask 077
          KC="$RUNNER_TEMP/build.keychain-db"
          KC_PW="$(uuidgen)"
          CERT="$RUNNER_TEMP/cert.p12"
          PROFILE="$RUNNER_TEMP/profile.mobileprovision"

          printf '%s' "$BUILD_CERTIFICATE_BASE64" | base64 --decode > "$CERT"
          printf '%s' "$PROVISIONING_PROFILE_BASE64" | base64 --decode > "$PROFILE"
          printf '%s' "$ASC_PRIVATE_KEY" | base64 --decode > "$RUNNER_TEMP/AuthKey_${ASC_KEY_ID}.p8"

          security create-keychain -p "$KC_PW" "$KC"
          security set-keychain-settings -lut 21600 "$KC"
          security unlock-keychain -p "$KC_PW" "$KC"
          security import "$CERT" -k "$KC" -P "$P12_PASSWORD" \
            -T /usr/bin/codesign -T /usr/bin/security
          # Append rather than replace -- `-s` alone drops login.keychain.
          security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
          # codesign: is REQUIRED. Without it macOS queues a GUI authorization
          # prompt that never arrives headless, and the job HANGS until the
          # timeout rather than failing. The shorter apple-tool:,apple: form
          # found in older guides is insufficient.
          security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$KC_PW" "$KC" >/dev/null

          mkdir -p ~/Library/MobileDevice/Provisioning\ Profiles
          UUID="$(security cms -D -i "$PROFILE" | plutil -extract UUID raw -)"
          cp "$PROFILE" ~/Library/MobileDevice/Provisioning\ Profiles/"$UUID".mobileprovision

          rm -f "$CERT" "$PROFILE"
          security find-identity -v -p codesigning "$KC"

      - name: Archive and export
        env:
          ASC_KEY_PATH: ${{ runner.temp }}/AuthKey_${{ secrets.ASC_KEY_ID }}.p8
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
          BUILD_NUMBER: ${{ steps.buildnum.outputs.value }}
          EXPORT_OPTIONS_PLIST: App/ExportOptions-ci.plist
        run: Scripts/archive.sh

      # BEFORE the upload, so a failed upload does not discard the build.
      - name: Upload IPA artifact
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4
        with:
          name: WADdle-${{ steps.buildnum.outputs.value }}-ipa
          path: Vendor/archive/export/*.ipa
          retention-days: 7

      - name: Upload to TestFlight
        env:
          ASC_KEY_PATH: ${{ runner.temp }}/AuthKey_${{ secrets.ASC_KEY_ID }}.p8
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
          VALIDATE_ONLY: ${{ inputs.validate_only }}
        run: |
          if [ "$VALIDATE_ONLY" = "true" ]; then
            Scripts/upload.sh --validate
          else
            Scripts/upload.sh
          fi

      # xcdistributionlogs are the only diagnostic for a signing failure, but
      # they can contain the ASC key id and account emails -- and artifacts on
      # a public repo are publicly downloadable. Failure only, short retention.
      - name: Capture distribution logs
        if: failure()
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4
        with:
          name: xcdistributionlogs
          path: ~/Library/Logs/gym/**/*.xcdistributionlogs
          retention-days: 3
          if-no-files-found: ignore

      # Unconditional: if a build number was consumed, the run must say so
      # even on failure. App Store Connect is the only other record.
      - name: Summary
        if: always()
        run: |
          {
            echo "### TestFlight run"
            echo ""
            echo "- Build number: **${{ steps.buildnum.outputs.value }}**"
            echo "- Mode: ${{ inputs.validate_only == true && 'validate only' || 'upload' }}"
            echo "- Ref: \`${{ github.ref_name }}\`"
            echo ""
            echo "Confirm the build appears in App Store Connect. Xcode 26's altool"
            echo "can report success for an upload that did not happen, so a green"
            echo "run is not by itself proof of delivery."
          } >> "$GITHUB_STEP_SUMMARY"

      - name: Delete keychain
        if: always()
        run: |
          security delete-keychain "$RUNNER_TEMP/build.keychain-db" 2>/dev/null || true
          rm -f "$RUNNER_TEMP"/AuthKey_*.p8
```

- [ ] **Step 3: Lint**

```bash
actionlint
```

Expected: no output, exit 0. Fix anything reported before committing.

- [ ] **Step 4: Verify the plist is well-formed**

```bash
plutil -lint App/ExportOptions-ci.plist
```

Expected: `App/ExportOptions-ci.plist: OK`

- [ ] **Step 5: Confirm the export plist override reaches archive.sh**

```bash
ARCHIVE_PRINT_ONLY=1 EXPORT_OPTIONS_PLIST=App/ExportOptions-ci.plist /bin/bash Scripts/archive.sh | grep ExportOptions-ci
```

Expected: the `EXPORT:` line, showing `App/ExportOptions-ci.plist`.

- [ ] **Step 6: Commit and push**

```bash
git add App/ExportOptions-ci.plist .github/workflows/testflight.yml
git commit -m "feat(ci): add the TestFlight release workflow

Manual dispatch only, with validate_only and build_number inputs. Signs with a
certificate and profile installed from secrets into an ephemeral keychain, and
uses a manual-signing export plist so xcodebuild never gains portal write
authority.

The build number is run_number plus a documented offset, validated before the
archive. Commit count was rejected: actions/checkout defaults to a shallow
clone, where git rev-list --count HEAD returns 1 -- a number already consumed.

Engine is rebuilt from source rather than restored from cache so the shipped
binary is reproducible from the tree."
git push -u origin tylervick/testflight-ci
```

- [ ] **Step 7: Open the PR**

```bash
gh pr create --title "TestFlight release workflow" --body "$(cat <<'EOF'
Adds a manually-dispatched workflow that archives, signs and uploads to TestFlight.

- `testflight.yml` — dispatch-only, with `validate_only` and `build_number` inputs
- `skip-cache` input on the composite action, so releases rebuild the engine from source
- `archive.sh` / `upload.sh` gain env-driven ASC auth, build-number and export-plist
  support; inert when unset, covered by `Scripts/test-release-args.sh`
- `ExportOptions-ci.plist` — manual signing, so `xcodebuild` cannot mint certificates
- Actions on the release path pinned to the commits their current major tags resolve to

Design: `docs/superpowers/specs/2026-07-29-testflight-ci-design.md`

**Not yet verified on CI.** The first dispatch must be `validate_only: true`.
EOF
)"
```

Do **not** dispatch the workflow yet — Task 4 covers that deliberately.

---

### Task 4: Verify on CI, then correct the stale documentation

**Files:**
- Modify: `docs/app-store/submission-checklist.md`

**Interfaces:**
- Consumes: everything from Tasks 1-3.
- Produces: nothing.

- [ ] **Step 1: Dispatch a validate-only run**

```bash
gh workflow run testflight.yml --ref tylervick/testflight-ci -f validate_only=true
gh run watch
```

This exercises the keychain, profile installation, manual signing, archive and
export — everything except the irreversible step — without consuming a build
number. Expect roughly 25-30 minutes, since the engine is rebuilt from source.

If it fails, read the log and fix forward. Likely failure points, in order:

- **`No signing certificate "Apple Distribution" found`** — the keychain search
  list or partition list. Re-check the `list-keychains` and
  `set-key-partition-list` lines against Task 3.
- **The job hangs with no output during archive** — this is the missing
  `codesign:` partition-list symptom. It will run to the 90-minute timeout.
  Cancel it rather than waiting.
- **`No profiles for 'com.tylervick.waddle' were found`** — the profile did not
  install, or its name does not match the `provisioningProfiles` map in
  `ExportOptions-ci.plist`.

Do NOT add `-allowProvisioningUpdates` to the archive step to work around a
signing failure. That reintroduces certificate minting, which is the one
irreversible failure in this design.

- [ ] **Step 2: Dispatch a real upload**

```bash
gh workflow run testflight.yml --ref tylervick/testflight-ci
gh run watch
```

Expected: build **201** uploads. Note the number from the run summary.

- [ ] **Step 3: Confirm delivery independently**

Check App Store Connect for the build. This step is not optional: Xcode 26's
`altool` can report success for an upload that did not happen, so the run
going green is not proof of delivery. `upload.sh` inspects the output for
`ERROR ITMS-` markers, which narrows the window but does not close it.

- [ ] **Step 4: Rewrite the stale sections of the submission checklist**

`docs/app-store/submission-checklist.md` §1 still says export fails with
`No profiles for 'com.tylervick.waddle' were found` and calls that "the current
state"; §2 documents Xcode Organizer or manual Transporter as the upload path.
Builds 1-6 have shipped since, and CI now handles this.

Replace the §2 build-and-upload steps with the CI procedure: dispatch
`testflight.yml`, first with `validate_only: true` if signing changed, then for
real; the build number is derived automatically; confirm in App Store Connect.
Delete the §1 note claiming export currently fails. Leave the App Store Connect
form-filling sections (§3-§5) untouched — they remain accurate and human-only.

Add a short note recording that the certificate expires **2027-05-02** and the
provisioning profile **2027-07-20**, and that both present as opaque signing
errors rather than anything mentioning expiry.

- [ ] **Step 5: Commit and update the PR**

```bash
git add docs/app-store/submission-checklist.md
git commit -m "docs(app-store): replace the manual release steps with CI

The checklist described an export that fails with 'no profiles found' as the
current state, and Xcode Organizer as the upload path. Builds 1-6 have shipped
since and releases now run from testflight.yml. Records both signing-asset
expiry dates, since neither failure announces itself as an expiry."
git push
gh pr comment --body "Verified on CI:
- validate-only run: <URL>
- upload run: <URL>, build <N>
- Confirmed present in App Store Connect: <yes/no>"
```

Fill in the real URLs and build number.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Manual signing, pre-installed profile, no portal write authority | Task 3 (plist), Task 1 (no `-allowProvisioningUpdates` on archive) |
| Full keychain step list incl. `list-keychains` and `codesign:` | Task 3 Step 2 |
| Build number = 200 + run_number, override, pre-archive validation | Task 3 Step 2 |
| `skip-cache`, releases rebuild from source | Task 2 |
| `archive.sh` env-driven extension, bash 3.2 guard, tested | Task 1 |
| `upload.sh` `--p8-file-path` + output verification | Task 1 |
| `.p8` handling: base64, `printf`, `RUNNER_TEMP`, `umask 077`, no `set -x` | Task 3 Step 2 |
| Concurrency ref-independent, `cancel-in-progress: false` | Task 3 Step 2 |
| `permissions`, `timeout-minutes`, `retention-days` | Task 3 Step 2 |
| Artifact before upload; summary unconditional; logs on failure only | Task 3 Step 2 |
| SHA pins on the release path | Task 2 (composite), Task 3 (workflow) |
| `xcode-version` into `env:` | Task 2 Step 2 |
| First dispatch is `validate_only` | Task 4 Step 1 |
| Submission checklist is stale | Task 4 Step 4 |
| Expiry dates recorded | Task 3 Step 1 (plist comment), Task 4 Step 4 (checklist) |

**Placeholder scan:** no TBD/TODO. The only blanks are the run URLs and build
number in Task 4 Step 5, which are runtime values that cannot exist beforehand.

**Type consistency:** `ASC_KEY_PATH`, `ASC_KEY_ID`, `ASC_ISSUER_ID`,
`BUILD_NUMBER`, `EXPORT_OPTIONS_PLIST` and `ARCHIVE_PRINT_ONLY` are spelled
identically in Task 1's implementation, Task 1's tests, and Task 3's workflow.
`skip-cache` matches between Task 2's definition and Task 3's use. The profile
name in `ExportOptions-ci.plist` matches the profile installed in Task 3 Step 2.

**Two things resolved during writing, worth flagging:**

1. The action SHAs pin the **currently used** major tags (`@v2`, `@v4`), not
   the latest releases. `checkout` is now on v7, `cache` on v6 and
   `mise-action` on v4 — pinning to those would have been four silent major
   upgrades wearing a pin's clothing.
2. `archive.sh` cannot be tested by stubbing `xcodebuild` on `PATH`, because
   its export step deliberately runs `PATH="/usr/bin:$PATH" xcodebuild` and
   would find the real binary ahead of any stub — the same trap that broke the
   first draft of PR #11's guard test. Hence `ARCHIVE_PRINT_ONLY`.
