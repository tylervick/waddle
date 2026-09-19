#!/bin/bash
# Tests for Scripts/upload.sh's altool error detection.
#
# Fully HERMETIC: stubs `xcrun` on a controlled PATH and feeds it canned
# altool transcripts. Nothing here touches App Store Connect, a real IPA, or
# this machine's Xcode.
#
# Bought by issue #240: on 2026-09-19 App Store Connect rejected build 254
# with a 409 ("The train version '1.1' is closed for new build submissions"),
# altool exited 0, and the guard's pattern -- `ERROR ITMS-|error:` -- matched
# none of the rejection's lines (uppercase `ERROR:`, no ITMS code). The upload
# step went green, a `build-254` tag was pushed for a binary Apple never
# accepted, and the notes step polled for a build that did not exist. The
# nightly repeated it as build 255 the same day.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# The stub prints whatever transcript the case put in $STUB_ALTOOL_OUT and
# exits with $STUB_ALTOOL_RC, so each case controls both of altool's outputs
# independently -- the whole point of the guard is that the two can disagree.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/xcrun" <<'STUB'
#!/bin/bash
if [ "$1" = "altool" ]; then
    cat "$STUB_ALTOOL_OUT"
    exit "${STUB_ALTOOL_RC:-0}"
fi
echo "stub xcrun: unhandled args: $*" >&2
exit 64
STUB
chmod +x "$TMP/bin/xcrun"
: > "$TMP/Waddle.ipa"

# Runs upload.sh against the stub. Credentials are dummies: they only ever
# reach the stub. Returns upload.sh's exit status; output lands in $TMP/out.
upload() { # transcript-file rc
    env PATH="$TMP/bin:/usr/bin:/bin" ASC_KEY_ID=KEYID ASC_ISSUER_ID=ISSUER \
        STUB_ALTOOL_OUT="$1" STUB_ALTOOL_RC="$2" \
        "$ROOT/Scripts/upload.sh" "$TMP/Waddle.ipa" >"$TMP/out" 2>&1
}

# 1. The 2026-09-19 rejection, verbatim (issue #240), with altool exiting 0.
#    This is the shape the old pattern missed: `ERROR:` in caps, no `ITMS-`.
cat > "$TMP/closed-train.txt" <<'EOF'
Running altool at path '/Applications/Xcode_26.2.app/Contents/SharedFrameworks/ContentDelivery.framework/Resources/altool'...
2026-09-19 06:59:46.187 ERROR: [ContentDelivery.Uploader.104ACAED0]
UPLOAD FAILED with 2 errors
2026-09-19 06:59:46.190 ERROR: [altool.104ACAED0] Validation failed (409) Invalid Pre-Release Train. The train version '1.1' is closed for new build submissions (ID: 66c04c00-d08c-43f7-a2b8-8fc88aa72b29)
   NSUnderlyingError : Validation failed (-19241) Invalid Pre-Release Train. The train version '1.1' is closed for new build submissions
      status : 409
      code : STATE_ERROR.VALIDATION_ERROR
   iris-code : STATE_ERROR.VALIDATION_ERROR
   NSUnderlyingError : Validation failed (-19241) This bundle is invalid. The value for key CFBundleShortVersionString [1.1] in the Info.plist file must contain a higher version than that of the previously approved version [1.1].
EOF
if upload "$TMP/closed-train.txt" 0; then
    fail "the 409 closed-train rejection with exit 0 was reported as a successful upload"
fi
grep -q "treating this as a FAILED upload" "$TMP/out" \
    || fail "closed-train rejection refused, but not for the guard's reason; got: $(cat "$TMP/out")"
pass "refuses the 2026-09-19 closed-train rejection even though altool exited 0"

# 2. A genuine success must still pass. "no errors" and "No errors uploading"
#    are exactly the words a clean upload prints, so a pattern that merely
#    grew case-insensitive on `error` would refuse every real release.
cat > "$TMP/clean.txt" <<'EOF'
Running altool at path '/Applications/Xcode_26.2.app/Contents/SharedFrameworks/ContentDelivery.framework/Resources/altool'...
UPLOAD SUCCEEDED with no errors
No errors uploading archive at '/Users/runner/work/waddle/waddle/Vendor/archive/export/Waddle.ipa'.
EOF
upload "$TMP/clean.txt" 0 || fail "a clean transcript was refused; got: $(cat "$TMP/out")"
pass "accepts a clean 'UPLOAD SUCCEEDED with no errors' transcript"

# 2b. Same for --validate-app's wording.
cat > "$TMP/clean-validate.txt" <<'EOF'
No errors validating archive at '/Users/runner/work/waddle/waddle/Vendor/archive/export/Waddle.ipa'.
EOF
env PATH="$TMP/bin:/usr/bin:/bin" ASC_KEY_ID=KEYID ASC_ISSUER_ID=ISSUER \
    STUB_ALTOOL_OUT="$TMP/clean-validate.txt" STUB_ALTOOL_RC=0 \
    "$ROOT/Scripts/upload.sh" --validate "$TMP/Waddle.ipa" >"$TMP/out" 2>&1 \
    || fail "a clean --validate transcript was refused; got: $(cat "$TMP/out")"
pass "accepts a clean --validate transcript"

# 3. The Xcode 26 shape the guard was originally written for: an ITMS error
#    with exit 0. Must keep being caught.
cat > "$TMP/itms.txt" <<'EOF'
*** Error: ERROR ITMS-90062: "This bundle is invalid. The value for key CFBundleShortVersionString [1.1] in the Info.plist file must contain a higher version than that of the previously approved version [1.1]." (-19241)
Successfully uploaded.
EOF
if upload "$TMP/itms.txt" 0; then
    fail "an ITMS error with exit 0 was reported as a successful upload"
fi
pass "still refuses an ITMS error that altool exited 0 on"

# 4. A lowercase `error:` line with exit 0 -- the other half of the original
#    pattern -- is still refused.
printf 'error: something went wrong\n' > "$TMP/lower.txt"
if upload "$TMP/lower.txt" 0; then
    fail "a lowercase 'error:' line with exit 0 was reported as a successful upload"
fi
pass "still refuses a lowercase 'error:' line"

# 5. A non-zero altool exit is refused on its own, whatever the transcript
#    says, and the status is reported rather than reinterpreted.
if upload "$TMP/clean.txt" 3; then
    fail "altool exit 3 with a clean-looking transcript was reported as success"
fi
grep -q "altool exited 3" "$TMP/out" || fail "non-zero altool exit not reported; got: $(cat "$TMP/out")"
pass "refuses a non-zero altool exit regardless of the transcript"

# 6. Discrimination against a near miss: "errors" as a plain word, and a URL
#    that happens to contain "error", must not trip the guard. This is what
#    keeps case 2 honest -- a pattern loose enough to catch case 1 by
#    accident would fail here.
cat > "$TMP/near-miss.txt" <<'EOF'
Checking for errors in the archive before upload...
See https://help.apple.com/asc/error-codes for the meaning of any codes below.
UPLOAD SUCCEEDED with no errors
EOF
upload "$TMP/near-miss.txt" 0 || fail "a transcript mentioning 'errors' and an 'error-codes' URL was refused; got: $(cat "$TMP/out")"
pass "does not trip on the word 'errors' or an 'error-codes' URL"

echo "All upload tests passed."
