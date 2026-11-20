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

# 7. Issue 390, verbatim from run 44155695412 (2026-11-17, build 293):
#    altool's own App Store Connect lookup got two 500s, printed each as
#    `ERROR:`, retried, and then delivered the build. Refusing this stopped
#    the release before its tag step, with the build already in App Store
#    Connect. The INFO line's trailing space is altool's.
cat > "$TMP/transient-then-delivered.txt" <<'EOF'
Running altool at path '/Applications/Xcode_27.1.app/Contents/SharedFrameworks/ContentDelivery.framework/Resources/altool'...

2026-11-17 19:57:32.140 ERROR: [CDASCAPI.7BD1045340] APP STORE CONNECT API list-apps: received status code 500; internal server error. (5T5PUN6AY4BGUULTX2YLL3O5VI) (500)
2026-11-17 19:57:37.184 ERROR: [CDASCAPI.7BD1045340] APP STORE CONNECT API list-apps: received status code 500; internal server error. (PEPXYABI6PJRHVEVYAR5ZXLACY) (500)
2026-11-17 19:59:06.243  INFO: [ContentDelivery.Uploader.7BD1045340] 
==========================================
UPLOAD SUCCEEDED with no errors
Delivery UUID: 2b3803a9-1144-4110-aa1f-a180096dd901
Transferred 32623126 bytes in 2.990 seconds (10.9MB/s, 87.280Mbps)
==========================================
No errors uploading archive at '/Users/runner/work/waddle/waddle/Vendor/archive/export/Waddle.ipa'.
EOF
upload "$TMP/transient-then-delivered.txt" 0 \
    || fail "two retried 500s followed by a confirmed delivery were refused; got: $(cat "$TMP/out")"
grep -q "2 transient App Store Connect error(s), then Delivery UUID: 2b3803a9-1144-4110-aa1f-a180096dd901" "$TMP/out" \
    || fail "the forgiven errors were not reported with their count and the delivery; got: $(cat "$TMP/out")"
pass "accepts retried App Store Connect 500s that end in a confirmed delivery, and says so"

# Each case below is case 7 with ONE thing changed, and each must still be
# refused: together they are the proof that case 7 passes for its own reason
# and not because `ERROR:` stopped mattering.
variant() { # name sed-program...
    local name="$1"; shift
    sed "$@" "$TMP/transient-then-delivered.txt" > "$TMP/$name.txt"
    cmp -s "$TMP/$name.txt" "$TMP/transient-then-delivered.txt" \
        && fail "variant '$name' is identical to the transcript it should differ from"
    return 0
}
refused() { # name description
    if upload "$TMP/$1.txt" 0; then
        fail "$2 was reported as a successful upload"
    fi
    grep -q "treating this as a FAILED upload" "$TMP/out" \
        || fail "$2 was refused, but not by the guard; got: $(cat "$TMP/out")"
}

# 8. The 500s with no success block: the retry never recovered.
variant no-success -e '/^UPLOAD SUCCEEDED/,$d'
refused no-success "retried 500s with no UPLOAD SUCCEEDED block"
grep -q "MAY be in" "$TMP/out" \
    && fail "a transcript with no UPLOAD SUCCEEDED line was told its build may be uploaded"
pass "still refuses retried 500s that never reach UPLOAD SUCCEEDED"

# 9. A success line with no Delivery UUID under it.
variant no-uuid -e '/^Delivery UUID:/d'
refused no-uuid "UPLOAD SUCCEEDED with no Delivery UUID"
pass "still refuses a success line that no Delivery UUID follows"

# 10. An error that is not a 5xx from an App Store Connect call. A 4xx is an
#     answer (401: the key is wrong; 409: the build is refused), not a hiccup.
variant client-error -e '3s/status code 500; internal server error\./status code 401; unauthorized./'
refused client-error "a 401 from App Store Connect followed by UPLOAD SUCCEEDED"
pass "still refuses a 4xx from App Store Connect, whatever follows it"

# 11. An `ERROR:` of any other shape alongside the forgivable ones.
variant other-error -e '4s/.*/2026-11-17 19:57:37.184 ERROR: [altool.7BD1045340] Validation failed (409) Invalid Pre-Release Train./'
refused other-error "a non-transient ERROR beside a retried 500"
pass "still refuses any other ERROR line, even beside a forgivable one"

# 12. A 5xx AFTER the success block: nothing confirms a delivery after it.
variant error-after -e '$a\
2026-11-17 19:59:07.000 ERROR: [CDASCAPI.7BD1045340] APP STORE CONNECT API list-builds: received status code 503; service unavailable. (X) (503)'
refused error-after "a 5xx printed after UPLOAD SUCCEEDED"
pass "still refuses a 5xx that arrives after the success block"

# 13. An ITMS code beside the forgivable lines: the Xcode 26 case, where the
#     success line is the thing that lies.
#     The line carries no `error:` of its own, so only the ITMS rule sees it.
variant itms-too -e '5i\
ITMS-90062 This bundle is invalid.'
refused itms-too "an ITMS error beside retried 500s and UPLOAD SUCCEEDED"
pass "still refuses an ITMS code, whatever else the transcript says"

# 13b. Two success blocks: not a transcript altool has produced, so not one
#      to wave through.
variant twice -e '$a\
UPLOAD SUCCEEDED with no errors\
Delivery UUID: 2b3803a9-1144-4110-aa1f-a180096dd901'
refused twice "a transcript with two UPLOAD SUCCEEDED blocks"
pass "still refuses a transcript that reports success twice"

# 14. --validate has no delivery to confirm, so the exception never applies.
if env PATH="$TMP/bin:/usr/bin:/bin" ASC_KEY_ID=KEYID ASC_ISSUER_ID=ISSUER \
    STUB_ALTOOL_OUT="$TMP/transient-then-delivered.txt" STUB_ALTOOL_RC=0 \
    "$ROOT/Scripts/upload.sh" --validate "$TMP/Waddle.ipa" >"$TMP/out" 2>&1; then
    fail "--validate forgave an ERROR line"
fi
pass "never forgives an ERROR line under --validate"

# 15. A refusal that follows an UPLOAD SUCCEEDED line says the build may be
#     uploaded and names the tag repair. In issue 390 the step said only
#     "Verify in App Store Connect"; the repair is printed by the tag step,
#     which never ran.
refused error-after "a 5xx printed after UPLOAD SUCCEEDED"
grep -q "MAY be in" "$TMP/out" && grep -q "push that tag by hand" "$TMP/out" \
    && grep -q "docs/app-store/submission-checklist.md" "$TMP/out" \
    || fail "a refusal after UPLOAD SUCCEEDED did not give the tag repair; got: $(cat "$TMP/out")"
pass "a refusal after UPLOAD SUCCEEDED says the build may be uploaded and how to tag it"

echo "All upload tests passed."
