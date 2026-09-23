#!/bin/bash
# Tests for Scripts/upload-screenshots.sh.
#
# HERMETIC: curl is a strict stub on a controlled PATH that plays App Store
# Connect from fixtures and logs every call; the JWT comes from a fake ASC_JWT;
# the screenshots are generated PNG headers of the right sizes. Nothing here
# contacts App Store Connect.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

SCRIPT="$ROOT/Scripts/upload-screenshots.sh"
SLOTS="05-ingame 01-play-tab 02-library 03-preset-editor 06-automap 04-control-feel"

# A PNG that is only a signature, an IHDR and an IEND: enough for every size
# and chunk check the script makes, and a few dozen bytes on disk.
make_png() { # path width height [exif]
    python3 - "$@" <<'PY'
import struct, sys, zlib
path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
if len(sys.argv) > 4:
    data += chunk(b"eXIf", b"MM\x00*")
data += chunk(b"IEND", b"")
open(path, "wb").write(data)
PY
}

# Fresh world per case: screenshots, fixtures, stub, empty call log.
setup() {
    rm -rf "$TMP/w"; mkdir -p "$TMP/w/bin" "$TMP/w/fix" "$TMP/w/shots/iphone-6.9" "$TMP/w/shots/ipad-13"
    for s in $SLOTS; do
        make_png "$TMP/w/shots/iphone-6.9/$s.png" 2868 1320
        make_png "$TMP/w/shots/ipad-13/$s.png" 2752 2064
    done
    F="$TMP/w/fix"
    cat > "$F/versions.json" <<'JSON'
{"data":[
 {"id":"V12","attributes":{"versionString":"1.2","appVersionState":"PREPARE_FOR_SUBMISSION"}},
 {"id":"V11","attributes":{"versionString":"1.1","appVersionState":"READY_FOR_DISTRIBUTION"}}]}
JSON
    echo '{"data":[{"id":"L12","attributes":{"locale":"en-US"}}]}' > "$F/loc-V12.json"
    echo '{"data":[{"id":"L11","attributes":{"locale":"en-US"}}]}' > "$F/loc-V11.json"
    cat > "$F/sets-L12.json" <<'JSON'
{"data":[{"id":"S12P","attributes":{"screenshotDisplayType":"APP_IPHONE_67"}},
         {"id":"S12I","attributes":{"screenshotDisplayType":"APP_IPAD_PRO_3GEN_129"}}]}
JSON
    cat > "$F/sets-L11.json" <<'JSON'
{"data":[{"id":"S11P","attributes":{"screenshotDisplayType":"APP_IPHONE_67"}},
         {"id":"S11I","attributes":{"screenshotDisplayType":"APP_IPAD_PRO_3GEN_129"}}]}
JSON
    echo '{"data":[{"id":"old-1"},{"id":"old-2"}]}' > "$F/shots-S12P.json"
    echo '{"data":[{"id":"old-3"}]}' > "$F/shots-S12I.json"
    echo "COMPLETE" > "$F/state"
    echo "2868 1320" > "$F/dims"
    make_png "$F/render.png" 400 184

    # The stub. Routes by method + URL; answers api()-style calls (-o FILE
    # -w CODE) with a body file and a status, and -f calls with an exit code.
    # Anything it does not recognise exits 64, so a new call cannot pass
    # silently.
    cat > "$TMP/w/bin/curl" <<STUB
#!/usr/bin/env python3
import json, os, re, shutil, sys
F = "$F"
args = sys.argv[1:]
method, out, wfmt, data, url, fflag, hdr = "GET", None, None, None, None, False, None
i = 0
while i < len(args):
    a = args[i]
    if a == "-X": method = args[i + 1]; i += 1
    elif a == "-o": out = args[i + 1]; i += 1
    elif a == "-w": wfmt = args[i + 1]; i += 1
    elif a == "-D": hdr = args[i + 1]; i += 1
    elif a == "--data-binary": data = args[i + 1]; i += 1
    elif a in ("-H", "--connect-timeout", "--max-time"): i += 1
    elif a == "-f": fflag = True
    elif a.startswith("http"): url = a
    i += 1
body_len = os.path.getsize(data[1:]) if data and data.startswith("@") else 0
with open(F + "/../calls.log", "a") as log:
    log.write(f"{method} {url} {body_len}\n")
    if method == "PATCH" and "relationships" in (url or ""):
        log.write("ORDER " + open(data[1:]).read() + "\n")

def fail_here():
    p = F + "/fail"
    return os.path.exists(p) and open(p).read().strip() in f"{method} {url}"

def reply(code, doc=None, path=None, headers=""):
    if hdr:
        open(hdr, "w").write(f"HTTP/2 {code}\r\n{headers}\r\n")
    if fflag:
        if code >= 400: sys.exit(22)
        if out and out != "/dev/null":
            shutil.copy(path, out) if path else open(out, "w").write(json.dumps(doc or {}))
        sys.exit(0)
    if out:
        if path: shutil.copy(path, out)
        else: open(out, "w").write(json.dumps(doc) if doc is not None else "")
    sys.stdout.write(str(code))
    sys.exit(0)

if fail_here(): reply(500, {"errors": [{"status": "500", "detail": "injected"}]})
# Rate limit: "N substring" in F/rate429 answers the next N matching calls 429.
rl = F + "/rate429"
if os.path.exists(rl):
    left, sub = open(rl).read().strip().split(" ", 1)
    if int(left) > 0 and sub in f"{method} {url}":
        open(rl, "w").write(f"{int(left) - 1} {sub}")
        reply(429, {"errors": [{"status": "429"}]}, headers="Retry-After: 7\r\n")
api = "https://api.appstoreconnect.apple.com"
path = (url or "").replace(api, "").split("?")[0]
m = re.fullmatch
if method == "GET" and m(r"/v1/apps/[^/]+/appStoreVersions", path): reply(200, path=F + "/versions.json")
if method == "GET" and (r := m(r"/v1/appStoreVersions/([^/]+)/appStoreVersionLocalizations", path)): reply(200, path=f"{F}/loc-{r[1]}.json")
if method == "GET" and (r := m(r"/v1/appStoreVersionLocalizations/([^/]+)/appScreenshotSets", path)): reply(200, path=f"{F}/sets-{r[1]}.json")
if method == "GET" and (r := m(r"/v1/appScreenshotSets/([^/]+)/appScreenshots", path)): reply(200, path=f"{F}/shots-{r[1]}.json")
if method == "DELETE" and m(r"/v1/appScreenshots/[\w-]+", path): reply(204)
if method == "POST" and path == "/v1/appScreenshots":
    req = json.load(open(data[1:]))["data"]
    size = req["attributes"]["fileSize"]
    n = len(open(F + "/../calls.log").read().split("POST ")) - 1
    half = size // 2
    ops = [{"method": "PUT", "url": f"https://upload.example.invalid/new-{n}/a", "offset": 0, "length": half,
            "requestHeaders": [{"name": "Content-Type", "value": "image/png"}]},
           {"method": "PUT", "url": f"https://upload.example.invalid/new-{n}/b", "offset": half, "length": size - half,
            "requestHeaders": [{"name": "Content-Type", "value": "image/png"}]}]
    reply(201, {"data": {"type": "appScreenshots", "id": f"new-{n}", "attributes": {"uploadOperations": ops}}})
if method == "PUT" and (url or "").startswith("https://upload.example.invalid/"): reply(200)
if method == "PATCH" and m(r"/v1/appScreenshots/[\w-]+", path): reply(200, {"data": {}})
if method == "GET" and (r := m(r"/v1/appScreenshots/([\w-]+)", path)):
    w, h = open(F + "/dims").read().split()
    reply(200, {"data": {"id": r[1], "attributes": {
        "assetDeliveryState": {"state": open(F + "/state").read().strip(), "errors": [{"code": "IMAGE_TOOL_FAILURE"}]},
        "imageAsset": {"width": int(w), "height": int(h),
                       "templateUrl": f"https://render.example.invalid/{r[1]}/{{w}}x{{h}}bb.{{f}}"}}}})
if method == "GET" and (url or "").startswith("https://render.example.invalid/"): reply(200, path=F + "/render.png")
if method == "PATCH" and m(r"/v1/appScreenshotSets/[^/]+/relationships/appScreenshots", path): reply(204)
sys.stderr.write(f"stub curl: unhandled {method} {url}\n"); sys.exit(64)
STUB
    chmod +x "$TMP/w/bin/curl"
    printf '#!/bin/bash\necho fake.jwt.token\n' > "$TMP/w/jwt"; chmod +x "$TMP/w/jwt"
    : > "$TMP/w/calls.log"
}

run() { # args... -- exit status in RC, combined output in OUT
    set +e
    OUT="$(env PATH="$TMP/w/bin:/usr/bin:/bin" ASC_JWT="$TMP/w/jwt" SCREENSHOTS_DIR="$TMP/w/shots" \
        ASC_APP_ID=APP UPLOAD_POLL_DELAY=0 UPLOAD_POLL_ATTEMPTS=3 API_RETRY_MAX_SLEEP=0 GITHUB_ACTIONS= \
        "$SCRIPT" --version 1.2 "$@" 2>&1)"
    RC=$?
    set -e
}
mutations() { grep -cE '^(POST|PATCH|DELETE|PUT) ' "$TMP/w/calls.log" || true; }

# 1. The default is a dry run: it reads everything and changes nothing. The
#    whole point of the default is that forgetting --apply is harmless.
setup; run
[ "$RC" = 0 ] || fail "dry run exited $RC: $OUT"
[ "$(mutations)" = 0 ] || fail "dry run made mutating calls: $(cat "$TMP/w/calls.log")"
echo "$OUT" | grep -q "dry run" || fail "dry run did not say so: $OUT"
echo "$OUT" | grep -q "S12P (APP_IPHONE_67) holds 2" || fail "dry run did not report the iPhone set: $OUT"
pass "dry run reads, reports and mutates nothing"

# 2. The happy path. Pins the three orderings the traps depend on: every old
#    shot deleted before the first reservation (the 10-per-set cap), each
#    upload committed, and the set's final order exactly the slot order.
setup; run --apply --device iphone
[ "$RC" = 0 ] || fail "apply exited $RC: $OUT"
first_post="$(grep -n '^POST ' "$TMP/w/calls.log" | head -1 | cut -d: -f1)"
last_delete="$(grep -n '^DELETE ' "$TMP/w/calls.log" | tail -1 | cut -d: -f1)"
[ -n "$last_delete" ] && [ "$last_delete" -lt "$first_post" ] || fail "a reservation came before the last delete"
[ "$(grep -c '^DELETE .*/old-[12] ' "$TMP/w/calls.log")" = 2 ] || fail "did not delete both old iPhone shots"
[ "$(grep -c '^POST ' "$TMP/w/calls.log")" = 6 ] || fail "expected 6 reservations"
[ "$(grep -c '^PUT https://upload' "$TMP/w/calls.log")" = 12 ] || fail "expected 12 part uploads (2 per shot)"
[ "$(grep -cE '^PATCH .*/v1/appScreenshots/new-[1-6] ' "$TMP/w/calls.log")" = 6 ] || fail "expected 6 upload commits"
grep -q '^ORDER {"data":\[{"type":"appScreenshots","id":"new-1"},{"type":"appScreenshots","id":"new-2"},{"type":"appScreenshots","id":"new-3"},{"type":"appScreenshots","id":"new-4"},{"type":"appScreenshots","id":"new-5"},{"type":"appScreenshots","id":"new-6"}\]}' "$TMP/w/calls.log" \
    || fail "slot order not pinned as uploaded: $(grep ORDER "$TMP/w/calls.log")"
! grep -qE 'S12I|S11P|S11I|old-3' "$TMP/w/calls.log" || fail "touched a set other than the iPhone target"
pass "apply deletes first, uploads, commits, verifies and pins slot order"

# 2b. The part uploads carry exactly the file's bytes, split as Apple asked.
size="$(wc -c < "$TMP/w/shots/iphone-6.9/05-ingame.png" | tr -d ' ')"
parts="$(grep '^PUT https://upload.example.invalid/new-1/' "$TMP/w/calls.log" | awk '{ s += $3 } END { print s }')"
[ "$parts" = "$size" ] || fail "uploaded $parts bytes of a $size-byte file"
pass "part uploads sum to the file size"

# 3. A version that is not editable (live, or in review) is refused before
#    any mutation.
setup; sed -i.bak 's/"PREPARE_FOR_SUBMISSION"/"WAITING_FOR_REVIEW"/' "$TMP/w/fix/versions.json"; run --apply
[ "$RC" != 0 ] || fail "accepted a version in WAITING_FOR_REVIEW"
[ "$(mutations)" = 0 ] || fail "mutated a non-editable version"
echo "$OUT" | grep -q "cannot be edited" || fail "wrong refusal: $OUT"
pass "non-editable version refused"

# 4. The metadata.md §12 check: if the target set id also belongs to a
#    non-editable version, deleting from it would empty the live listing.
setup; sed -i.bak 's/"S11P"/"S12P"/' "$TMP/w/fix/sets-L11.json"; run --apply
[ "$RC" != 0 ] || fail "accepted a set shared with the live version"
[ "$(mutations)" = 0 ] || fail "mutated a set shared with the live version"
echo "$OUT" | grep -q "non-editable version -- refusing" || fail "wrong refusal: $OUT"
pass "set shared with a live version refused"

# 5. Transposed reported dimensions are the sideways-store symptom seen at
#    the first upload; COMPLETE must not be taken as success on its own.
setup; echo "1320 2868" > "$TMP/w/fix/dims"; run --apply --device iphone
[ "$RC" != 0 ] || fail "accepted transposed dimensions"
echo "$OUT" | grep -q "transposed" || fail "wrong failure: $OUT"
pass "transposed dimensions fail"

# 6. A portrait rendition fails even when the reported size looks right.
setup; make_png "$TMP/w/fix/render.png" 184 400; run --apply --device iphone
[ "$RC" != 0 ] || fail "accepted a portrait rendition"
echo "$OUT" | grep -q "stored sideways" || fail "wrong failure: $OUT"
pass "portrait rendition fails"

# 7. A local file carrying an eXIf chunk is refused before any network call.
setup; make_png "$TMP/w/shots/ipad-13/02-library.png" 2752 2064 exif; run --apply
[ "$RC" != 0 ] || fail "accepted a PNG with eXIf"
[ ! -s "$TMP/w/calls.log" ] || fail "made network calls despite a bad local file"
echo "$OUT" | grep -q "eXIf" || fail "wrong failure: $OUT"
pass "eXIf chunk refused locally"

# 8. So is a file of the wrong size -- a portrait capture, say.
setup; make_png "$TMP/w/shots/iphone-6.9/01-play-tab.png" 1320 2868; run --apply
[ "$RC" != 0 ] || fail "accepted a wrongly-sized file"
[ ! -s "$TMP/w/calls.log" ] || fail "made network calls despite a bad local file"
pass "wrong local size refused"

# 9. A failed query fails closed with Apple's error visible -- it is never
#    read as "no versions" or "no screenshots".
setup; echo "GET https://api.appstoreconnect.apple.com/v1/apps/APP/appStoreVersions" > "$TMP/w/fix/fail"; run
[ "$RC" != 0 ] || fail "treated a 500 as an answer"
echo "$OUT" | grep -q "HTTP 500" || fail "did not surface the status: $OUT"
pass "API failure fails closed"

# 9b. Same for the listing of an old set's contents, which decides what gets
#     deleted.
setup; echo "appScreenshotSets/S12P/appScreenshots" > "$TMP/w/fix/fail"; run --apply
[ "$RC" != 0 ] || fail "treated a failed set listing as empty"
[ "$(mutations)" = 0 ] || fail "mutated after a failed set listing"
pass "failed set listing fails closed"

# 10. Apple rejecting the asset fails the run.
setup; echo "FAILED" > "$TMP/w/fix/state"; run --apply --device iphone
[ "$RC" != 0 ] || fail "accepted a FAILED delivery"
echo "$OUT" | grep -q "rejected" || fail "wrong failure: $OUT"
pass "FAILED delivery fails"

# 11. A missing display-type set is reported with what exists, not guessed at.
setup; echo '{"data":[{"id":"S12X","attributes":{"screenshotDisplayType":"APP_IPHONE_65"}}]}' > "$TMP/w/fix/sets-L12.json"; run
[ "$RC" != 0 ] || fail "accepted a version with no APP_IPHONE_67 set"
echo "$OUT" | grep -q "APP_IPHONE_65" || fail "did not list the sets it found: $OUT"
pass "missing display type reported with what exists"

# 12. Only a version-number shape reaches the API filters.
setup; run --version "1.2' or 1 or '"
[ "$RC" != 0 ] || fail "accepted a non-numeric version"
[ ! -s "$TMP/w/calls.log" ] || fail "made network calls with a bad version"
pass "non-numeric version refused"

# 13. No token, no run.
setup; printf '#!/bin/bash\nexit 1\n' > "$TMP/w/jwt"; run
[ "$RC" != 0 ] || fail "ran without a token"
[ ! -s "$TMP/w/calls.log" ] || fail "made network calls without a token"
pass "token failure stops the run"

# 14. One 429 is Apple saying "later": honour Retry-After (capped -- here to 0
#     so the suite does not sleep) and carry on, instead of failing a run that
#     may already have deleted the old shots.
setup; echo "1 POST https://api.appstoreconnect.apple.com/v1/appScreenshots" > "$TMP/w/fix/rate429"; run --apply --device iphone
[ "$RC" = 0 ] || fail "a single 429 failed the run: $OUT"
echo "$OUT" | grep -q "rate limited on POST" || fail "did not report the retry: $OUT"
echo "$OUT" | grep -q "retrying in 0s" || fail "Retry-After of 7 was not capped by API_RETRY_MAX_SLEEP=0: $OUT"
[ "$(grep -c '^POST ' "$TMP/w/calls.log")" = 7 ] || fail "expected 6 reservations plus 1 retried"
pass "a 429 is retried after Retry-After"

# 15. ...but not forever: a persistent 429 fails, with the status in view.
setup; echo "99 GET https://api.appstoreconnect.apple.com/v1/apps/" > "$TMP/w/fix/rate429"; run
[ "$RC" != 0 ] || fail "retried a persistent 429 forever, or ignored it"
echo "$OUT" | grep -q "HTTP 429 after 4 retries" || fail "wrong failure: $OUT"
pass "persistent 429 fails after the retry limit"

# 16. Ids come from the API and must stay data. The target version's id is
#     compared against every other version's inside a python expression; it
#     used to be spliced into that expression's text, so a quote in it was a
#     syntax error at best and code at worst.
setup; sed -i.bak "s/\"V12\"/\"V1'2\"/" "$TMP/w/fix/versions.json"
cp "$TMP/w/fix/loc-V12.json" "$TMP/w/fix/loc-V1'2.json"; run
[ "$RC" = 0 ] || fail "an id with a quote broke the run: $OUT"
echo "$OUT" | grep -q "version 1.2 (V1'2)" || fail "did not resolve the quoted id: $OUT"
grep -q "appStoreVersions/V11/appStoreVersionLocalizations" "$TMP/w/calls.log" \
    || fail "stopped protecting the other version"
pass "API ids are data, not code"

echo "All upload-screenshots tests passed."
