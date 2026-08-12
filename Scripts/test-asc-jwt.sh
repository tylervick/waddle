#!/bin/bash
# Tests for Scripts/asc-jwt.sh.
#
# HERMETIC: generates its own throwaway EC key. Never reads the real
# App Store Connect key, and never contacts App Store Connect.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# A real P-256 key, generated here so no fixture secret is ever committed.
openssl ecparam -genkey -name prime256v1 -noout -out "$TMP/key.p8" 2>/dev/null

mint() { env ASC_KEY_ID=ABC123 ASC_ISSUER_ID=iss-uuid ASC_KEY_PATH="$TMP/key.p8" \
             "$ROOT/Scripts/asc-jwt.sh"; }

# 1. Three dot-separated segments, none empty.
jwt="$(mint)"
[ "$(printf '%s' "$jwt" | awk -F. '{print NF}')" = "3" ] || fail "not three segments: $jwt"
for i in 1 2 3; do
    seg="$(printf '%s' "$jwt" | cut -d. -f$i)"
    [ -n "$seg" ] || fail "segment $i is empty"
done
pass "mints a three-segment JWT"

# 2. base64url only -- no '+', '/' or '=' anywhere. A standard-base64
#    signature is the single most likely defect here and App Store Connect
#    rejects it with a bare 401.
case "$jwt" in
    *+*|*/*|*=*) fail "JWT contains non-base64url characters: $jwt" ;;
esac
pass "uses base64url alphabet with no padding"

# 3. The header names ES256 and carries the key id; the payload carries the
#    issuer and the fixed audience.
b64url_decode() { # pads back to a multiple of 4
    s="$1"; while [ $(( ${#s} % 4 )) -ne 0 ]; do s="$s="; done
    printf '%s' "$s" | tr '_-' '/+' | openssl base64 -d -A
}
hdr="$(b64url_decode "$(printf '%s' "$jwt" | cut -d. -f1)")"
pay="$(b64url_decode "$(printf '%s' "$jwt" | cut -d. -f2)")"
case "$hdr" in *'"ES256"'*) ;; *) fail "header does not name ES256: $hdr" ;; esac
case "$hdr" in *'ABC123'*) ;; *) fail "header does not carry the key id: $hdr" ;; esac
case "$pay" in *'iss-uuid'*) ;; *) fail "payload does not carry the issuer: $pay" ;; esac
case "$pay" in *'appstoreconnect-v1'*) ;; *) fail "payload lacks the audience: $pay" ;; esac
pass "header and payload carry the required claims"

# 4. The signature is EXACTLY 64 raw bytes -- 32 for r, 32 for s. This is the
#    DER->JOSE conversion, and a 70-72 byte signature means the raw DER was
#    passed through unconverted.
sig_len="$(b64url_decode "$(printf '%s' "$jwt" | cut -d. -f3)" | wc -c | tr -d ' ')"
[ "$sig_len" = "64" ] || fail "signature is $sig_len bytes, expected 64 (DER not converted to JOSE?)"
pass "signature is 64 raw bytes, not DER"

# 5. Repeated mints with a key whose r or s is short still give 64 bytes.
#    A short integer must be LEFT-padded; without that the signature is 63
#    bytes roughly one time in 256 and the failure looks random.
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    l="$(b64url_decode "$(mint | cut -d. -f3)" | wc -c | tr -d ' ')"
    [ "$l" = "64" ] || fail "mint $n produced a $l-byte signature; padding is wrong"
done
pass "signature stays 64 bytes across repeated mints"

# 6. A missing key file fails loudly rather than emitting a malformed token.
if env ASC_KEY_ID=ABC123 ASC_ISSUER_ID=iss ASC_KEY_PATH="$TMP/nope.p8" \
       "$ROOT/Scripts/asc-jwt.sh" >"$TMP/out6" 2>&1; then
    fail "minted a JWT with no key file"
fi
grep -q "key" "$TMP/out6" || fail "error did not mention the key; got: $(cat "$TMP/out6")"
pass "fails loudly when the key file is missing"

echo "All asc-jwt tests passed."
