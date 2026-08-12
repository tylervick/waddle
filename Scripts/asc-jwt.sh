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
set -euo pipefail

: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH}"
[ -f "$ASC_KEY_PATH" ] || { echo "error: private key not found: $ASC_KEY_PATH" >&2; exit 1; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

NOW="$(date -u +%s)"
# 20 minutes. App Store Connect rejects a token whose lifetime exceeds 20
# minutes outright, so this is a ceiling, not a tuning choice.
EXP=$((NOW + 1200))

HEADER="$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$ASC_KEY_ID" | b64url)"
PAYLOAD="$(printf '{"iss":"%s","iat":%s,"exp":%s,"aud":"appstoreconnect-v1"}' \
             "$ASC_ISSUER_ID" "$NOW" "$EXP" | b64url)"
SIGNING_INPUT="$HEADER.$PAYLOAD"

# Sign, then convert DER to JOSE. The python3 step is stdlib only.
SIG="$(printf '%s' "$SIGNING_INPUT" \
        | openssl dgst -sha256 -sign "$ASC_KEY_PATH" \
        | python3 -c '
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
')"

printf '%s.%s\n' "$SIGNING_INPUT" "$SIG"
