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
