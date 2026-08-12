#!/bin/bash
# Tests for Scripts/asc-jwt.sh.
#
# HERMETIC: generates its own throwaway EC key. Never reads the real
# App Store Connect key, and never contacts App Store Connect.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
export TMP
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

# 7-8. Deterministic DER->JOSE fixtures, byte-for-byte.
#
# Case 5 above only exercises the left-pad/strip branches by hoping 20
# random signatures happen to produce a short r or s -- deleting the pad
# step still yields a correct 64-byte signature ~99% of the time, so that
# case is nearly useless as a regression guard. These two cases instead
# hand-craft DER containing every shape that needs converting and drive
# `asc-jwt.sh --der-to-jose` directly (see comment there), so the result is
# either exactly right or wrong every single time, never by chance.
#
# The raw signature bytes deliberately contain 0x00 (that's the whole point
# of testing padding), so they are written to files, never captured in a
# shell variable -- bash command substitution truncates at the first NUL.
b64url_decode_to_file() { # $1 = base64url string, $2 = output file
    s="$1"; while [ $(( ${#s} % 4 )) -ne 0 ]; do s="$s="; done
    printf '%s' "$s" | tr '_-' '/+' | openssl base64 -d -A > "$2"
}

python3 <<'PY'
import os
tmp = os.environ["TMP"]

def der_int(content):
    return bytes([0x02, len(content)]) + content

def der_seq(r_content, s_content):
    body = der_int(r_content) + der_int(s_content)
    return bytes([0x30, len(body)]) + body

# Fixture A: r is DER-short (31 bytes -- a real leading zero byte of the
# canonical 32-byte value was dropped because the next byte's top bit is
# clear); s carries DER's leading 0x00 sign-disambiguation byte (33 bytes)
# because its top bit is set.
r_a_canonical = b"\x00" + b"\x11" * 31
r_a_der = b"\x11" * 31
s_a_canonical = b"\xee" * 32
s_a_der = b"\x00" + b"\xee" * 32

with open(os.path.join(tmp, "der_a.bin"), "wb") as f:
    f.write(der_seq(r_a_der, s_a_der))
with open(os.path.join(tmp, "expected_a.bin"), "wb") as f:
    f.write(r_a_canonical + s_a_canonical)

# Fixture B: the mirror image -- r carries the leading zero, s is short.
r_b_canonical = b"\xff" * 32
r_b_der = b"\x00" + b"\xff" * 32
s_b_canonical = b"\x00" + b"\x22" * 31
s_b_der = b"\x22" * 31

with open(os.path.join(tmp, "der_b.bin"), "wb") as f:
    f.write(der_seq(r_b_der, s_b_der))
with open(os.path.join(tmp, "expected_b.bin"), "wb") as f:
    f.write(r_b_canonical + s_b_canonical)
PY

sig_a="$("$ROOT/Scripts/asc-jwt.sh" --der-to-jose < "$TMP/der_a.bin")"
b64url_decode_to_file "$sig_a" "$TMP/sig_a.bin"
cmp -s "$TMP/sig_a.bin" "$TMP/expected_a.bin" \
    || fail "DER->JOSE mismatch: short r / leading-zero s not converted correctly"
pass "a short r is left-padded and a leading-zero s is stripped, byte-for-byte"

sig_b="$("$ROOT/Scripts/asc-jwt.sh" --der-to-jose < "$TMP/der_b.bin")"
b64url_decode_to_file "$sig_b" "$TMP/sig_b.bin"
cmp -s "$TMP/sig_b.bin" "$TMP/expected_b.bin" \
    || fail "DER->JOSE mismatch: leading-zero r / short s not converted correctly"
pass "a leading-zero r is stripped and a short s is left-padded, byte-for-byte"

# 9. A corrupted key file fails loudly rather than emitting a malformed
# token (openssl fails to sign; der_to_jose then also refuses empty input).
printf 'not a real private key' > "$TMP/corrupt.p8"
if env ASC_KEY_ID=ABC123 ASC_ISSUER_ID=iss ASC_KEY_PATH="$TMP/corrupt.p8" \
       "$ROOT/Scripts/asc-jwt.sh" >"$TMP/out9" 2>"$TMP/err9"; then
    fail "minted a JWT with a corrupted key file"
fi
pass "fails loudly when the key file is corrupted"

# 10. An unreadable key file fails loudly too. Skipped when running as
# root, since root ignores permission bits and the check would be moot.
if [ "$(id -u)" != "0" ]; then
    printf 'irrelevant' > "$TMP/noperm.p8"
    chmod 000 "$TMP/noperm.p8"
    if env ASC_KEY_ID=ABC123 ASC_ISSUER_ID=iss ASC_KEY_PATH="$TMP/noperm.p8" \
           "$ROOT/Scripts/asc-jwt.sh" >"$TMP/out10" 2>"$TMP/err10"; then
        chmod 600 "$TMP/noperm.p8"
        fail "minted a JWT with an unreadable key file"
    fi
    chmod 600 "$TMP/noperm.p8"
    pass "fails loudly when the key file is unreadable"
else
    pass "skipped unreadable-key check (running as root)"
fi

# 11. ASC_KEY_ID / ASC_ISSUER_ID containing a quote and a backslash must not
# break the header/payload JSON. Round-trip through python3's json module
# (stdlib only) to confirm both the JSON stays well-formed and the escaped
# value decodes back to exactly what was passed in.
weird_id='AB"C\D'
weird_iss='iss"uer\backslash'
jwt_weird="$(env ASC_KEY_ID="$weird_id" ASC_ISSUER_ID="$weird_iss" \
                 ASC_KEY_PATH="$TMP/key.p8" "$ROOT/Scripts/asc-jwt.sh")"
hdr_weird="$(b64url_decode "$(printf '%s' "$jwt_weird" | cut -d. -f1)")"
pay_weird="$(b64url_decode "$(printf '%s' "$jwt_weird" | cut -d. -f2)")"

if ! kid_ok="$(printf '%s' "$hdr_weird" \
        | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["kid"])' 2>"$TMP/err11a")"; then
    fail "header is not valid JSON with a quote/backslash in kid: $(cat "$TMP/err11a")"
fi
if ! iss_ok="$(printf '%s' "$pay_weird" \
        | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["iss"])' 2>"$TMP/err11b")"; then
    fail "payload is not valid JSON with a quote/backslash in iss: $(cat "$TMP/err11b")"
fi
[ "$kid_ok" = "$weird_id" ] || fail "kid did not round-trip through JSON: got '$kid_ok'"
[ "$iss_ok" = "$weird_iss" ] || fail "iss did not round-trip through JSON: got '$iss_ok'"
pass "escapes a quote and a backslash in kid/iss so the header and payload stay valid JSON"

# 12. The token's lifetime is inside App Store Connect's hard 20-minute
#     (1200s) ceiling AND not sitting exactly on it. Apple rejects an
#     over-long lifetime with a bare 401 and no diagnostic, `iat` comes from
#     this machine's clock, and the request that would 401 is the one that
#     runs AFTER the upload has already consumed a build number -- so a
#     ceiling-hugging lifetime is a release failure waiting on a few seconds
#     of clock skew. Asserted from the decoded payload, so widening EXP
#     (1200, 3600, ...) cannot pass unnoticed.
iat_v="$(printf '%s' "$pay" | python3 -c 'import json,sys; print(json.load(sys.stdin)["iat"])')"
exp_v="$(printf '%s' "$pay" | python3 -c 'import json,sys; print(json.load(sys.stdin)["exp"])')"
life=$((exp_v - iat_v))
[ "$life" -le 1200 ] \
    || fail "token lifetime is ${life}s, over App Store Connect's 1200s ceiling: every request 401s"
[ "$life" -lt 1200 ] \
    || fail "token lifetime is exactly the 1200s ceiling; a few seconds of clock skew makes App Store Connect answer a bare 401 after the upload"
[ "$life" -ge 60 ] \
    || fail "token lifetime is only ${life}s, too short to survive a poll-and-attach run"
pass "token lifetime is under the 20-minute ceiling with headroom for clock skew"

echo "All asc-jwt tests passed."
