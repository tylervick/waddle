#!/bin/bash
# Mints one ES256 JWT for the App Store Connect REST API and prints it.
#
# Reads from the environment:
#   ASC_KEY_ID     the key's 10-character id (goes in the JWT header's kid)
#   ASC_ISSUER_ID  the issuer UUID
#   ASC_KEY_PATH   path to the .p8 private key
#
# WHY THIS EXISTS AT ALL: the obvious implementation is `import jwt`, but
# PyJWT is not on a GitHub macOS runner and adding a pip dependency to the
# release path is not worth it for ~30 lines. `openssl` can sign ES256; the
# only real work is that it emits an ASN.1 DER SEQUENCE { INTEGER r,
# INTEGER s } while JOSE requires the raw concatenation r||s with each value
# left-padded to exactly 32 bytes. DER drops leading zero bytes and adds one
# when the top bit is set, so neither field is reliably 32 bytes on the wire.
# Passing DER through unconverted yields a 70-72 byte signature, and App
# Store Connect answers a malformed signature with a bare 401 and no
# diagnostic -- which is why Scripts/test-asc-jwt.sh asserts the length is
# exactly 64 rather than merely that a token was produced.
#
# Also supports a `--der-to-jose` mode: reads a raw DER ECDSA signature on
# stdin and writes base64url(r||s), no padding, to stdout, then exits. This
# lets Scripts/test-asc-jwt.sh drive the exact conversion function used by
# the real signing path below with hand-crafted DER fixtures (a short r, an
# r carrying DER's leading 0x00 sign byte, ...) instead of relying on enough
# random mints happening to produce a short integer -- which they usually
# don't: a deleted padding step still yields a correct 64-byte signature
# well over 99% of the time.
set -euo pipefail

der_to_jose() {
    python3 -c '
import sys, base64
der = sys.stdin.buffer.read()
if not der or der[0] != 0x30:
    sys.exit("error: openssl did not emit a DER SEQUENCE")
# Skip the SEQUENCE tag and its length (short or long form).
i = 1
if der[i] & 0x80:
    i += 1 + (der[i] & 0x7F)
else:
    i += 1

def take_int(buf, pos):
    if buf[pos] != 0x02:
        sys.exit("error: expected a DER INTEGER")
    ln = buf[pos + 1]
    val = buf[pos + 2:pos + 2 + ln]
    # DER strips leading zeros and prepends one when the high bit is set;
    # JOSE wants a fixed 32-byte field either way.
    val = val.lstrip(b"\x00").rjust(32, b"\x00")
    if len(val) != 32:
        sys.exit("error: integer wider than 32 bytes")
    return val, pos + 2 + ln

r, i = take_int(der, i)
s, _ = take_int(der, i)
sys.stdout.write(base64.urlsafe_b64encode(r + s).decode().rstrip("="))
'
}

if [ "${1:-}" = "--der-to-jose" ]; then
    der_to_jose
    exit 0
fi

: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH}"
[ -f "$ASC_KEY_PATH" ] || { echo "error: private key not found: $ASC_KEY_PATH" >&2; exit 1; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# ASC_KEY_ID and ASC_ISSUER_ID are interpolated into JSON below; escape the
# two characters that would otherwise break it. (Apple issues both as
# fixed-format identifiers, so this is defense in depth rather than a fix
# for an observed value.)
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

NOW="$(date -u +%s)"
# 19 minutes, deliberately UNDER App Store Connect's hard 20-minute (1200s)
# ceiling rather than exactly at it. Apple rejects an over-long lifetime with
# a bare 401 and no diagnostic, and `iat` comes from this runner's clock: sit
# on the ceiling and a few seconds of clock skew between the runner and
# Apple turns every request 401, at the one point in the release where that
# happens AFTER the upload has consumed a build number. A minute of headroom
# costs nothing -- the attach finishes in seconds even after a full poll.
EXP=$((NOW + 1140))

KID_ESC="$(json_escape "$ASC_KEY_ID")"
ISS_ESC="$(json_escape "$ASC_ISSUER_ID")"

HEADER="$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$KID_ESC" | b64url)"
PAYLOAD="$(printf '{"iss":"%s","iat":%s,"exp":%s,"aud":"appstoreconnect-v1"}' \
             "$ISS_ESC" "$NOW" "$EXP" | b64url)"
SIGNING_INPUT="$HEADER.$PAYLOAD"

# Sign, then convert DER to JOSE via the same function --der-to-jose drives.
SIG="$(printf '%s' "$SIGNING_INPUT" \
        | openssl dgst -sha256 -sign "$ASC_KEY_PATH" \
        | der_to_jose)"

printf '%s.%s\n' "$SIGNING_INPUT" "$SIG"
