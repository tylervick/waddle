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
    rm -rf "$TMP/w"; mkdir -p "$TMP/w/bin" "$TMP/w/fix" "$TMP/w/shots/iphone-6.9" "$TMP/w/shots/ipad-13" \
        "$TMP/w/shots/iphone-duo"
    for s in $SLOTS; do
        make_png "$TMP/w/shots/iphone-6.9/$s.png" 2868 1320
        make_png "$TMP/w/shots/ipad-13/$s.png" 2752 2064
        make_png "$TMP/w/shots/iphone-duo/$s.png" 2034 1398
    done
    F="$TMP/w/fix"
    # The asset library, for the iPhone Duo set. The reference data is cut
    # down to what the script reads, in the shape Apple returned on 2026-11-20:
    # four exact sizes mapped to IPHONE_DUO_PROFILE, and a limit of 10.
    cat > "$F/refdata.json" <<'JSON'
{"data":[{"type":"appAssetLibraryRefData","id":"1","attributes":{
 "features":[{"featureId":"APP_STORE_VERSIONS","placementPolicies":[
   {"placementType":"APP_SCREENSHOT","groupLimits":[{"groupIds":["IPAD_13_PROFILE","IPHONE_DUO_PROFILE"],"maxCount":10}]}]}],
 "imageSpecs":[
   {"specId":"spec-ol","dimensions":{"minWidth":2034,"maxWidth":2034,"minHeight":1398,"maxHeight":1398}},
   {"specId":"spec-op","dimensions":{"minWidth":1398,"maxWidth":1398,"minHeight":2034,"maxHeight":2034}},
   {"specId":"spec-il","dimensions":{"minWidth":2853,"maxWidth":2853,"minHeight":2007,"maxHeight":2007}},
   {"specId":"spec-ip","dimensions":{"minWidth":2007,"maxWidth":2007,"minHeight":2853,"maxHeight":2853}},
   {"specId":"spec-pad","dimensions":{"minWidth":2752,"maxWidth":2752,"minHeight":2064,"maxHeight":2064}}],
 "placementTypes":[{"placementTypeId":"APP_SCREENSHOT","specMappings":[
   {"placementGroupId":"IPAD_13_PROFILE","specs":["spec-pad"]},
   {"placementGroupId":"IPHONE_DUO_PROFILE","specs":["spec-ol","spec-op","spec-il","spec-ip"]}]}]}}]}
JSON
    # What version 1.2 already has in the Duo group: two placements, each
    # naming 1.2's own localization.
    cat > "$F/placements-L12.json" <<'JSON'
{"data":[
 {"type":"appAssetLibraryPlacements","id":"oldp-1","attributes":{"placementGroup":"IPHONE_DUO_PROFILE","state":"ACTIVE"},
  "relationships":{"appStoreVersionLocalization":{"data":{"type":"appStoreVersionLocalizations","id":"L12"}}}},
 {"type":"appAssetLibraryPlacements","id":"oldp-2","attributes":{"placementGroup":"IPHONE_DUO_PROFILE","state":"ACTIVE"},
  "relationships":{"appStoreVersionLocalization":{"data":{"type":"appStoreVersionLocalizations","id":"L12"}}}}]}
JSON
    echo "COMPLETE" > "$F/duo-state"
    make_png "$F/render-landscape.png" 400 275
    make_png "$F/render-portrait.png" 275 400
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
    if method in ("POST", "PATCH") and "/v1/appAssetLibrary" in (url or ""):
        log.write("BODY " + open(data[1:]).read() + "\n")

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
        ra = open(F + "/retry-after").read().strip() if os.path.exists(F + "/retry-after") else "7"
        reply(429, {"errors": [{"status": "429"}]}, headers=f"Retry-After: {ra}\r\n")
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
    open(f"{F}/set-of-new-{n}", "w").write(req["relationships"]["appScreenshotSet"]["data"]["id"])
    reply(201, {"data": {"type": "appScreenshots", "id": f"new-{n}", "attributes": {"uploadOperations": ops}}})
if method == "PUT" and (url or "").startswith("https://upload.example.invalid/"): reply(200)
if method == "PATCH" and m(r"/v1/appScreenshots/[\w-]+", path): reply(200, {"data": {}})
if method == "GET" and (r := m(r"/v1/appScreenshots/([\w-]+)", path)):
    # One stored size for every set, unless a case gives a set its own
    # (F/dims-<set id>): only a run that uploads both sets needs two.
    own = f"{F}/dims-" + (open(f"{F}/set-of-{r[1]}").read() if os.path.exists(f"{F}/set-of-{r[1]}") else "")
    w, h = open(own if os.path.isfile(own) else F + "/dims").read().split()
    reply(200, {"data": {"id": r[1], "attributes": {
        "assetDeliveryState": {"state": open(F + "/state").read().strip(), "errors": [{"code": "IMAGE_TOOL_FAILURE"}]},
        "imageAsset": {"width": int(w), "height": int(h),
                       "templateUrl": f"https://render.example.invalid/{r[1]}/{{w}}x{{h}}bb.{{f}}"}}}})
if method == "GET" and (url or "").startswith("https://render.example.invalid/") and "/duo/" not in url: reply(200, path=F + "/render.png")
if method == "PATCH" and m(r"/v1/appScreenshotSets/[^/]+/relationships/appScreenshots", path): reply(204)

# ---- the asset library (iPhone Duo set). The stub keeps state in files so
# the read-back after an apply shows what the run actually created.
def lines(name):
    p = F + "/" + name
    return open(p).read().split() if os.path.exists(p) else []
def png_dims(p):
    b = open(p, "rb").read(24)
    return int.from_bytes(b[16:20], "big"), int.from_bytes(b[20:24], "big")
def image_dims(image_id):
    # The size App Store Connect "stored": the uploaded file's own, unless a
    # case overrides it to play the sideways store.
    if os.path.exists(F + "/duo-dims"):
        w, h = open(F + "/duo-dims").read().split(); return int(w), int(h)
    name = open(f"{F}/image-{image_id}").read().strip()
    return png_dims(F + "/../shots/iphone-duo/" + name.replace("iphone-duo-", "", 1))
if method == "GET" and m(r"/v1/apps/[^/]+/assetLibrary", path): reply(200, {"data": {"type": "appAssetLibraries", "id": "LIB"}})
if method == "GET" and path == "/v1/appAssetLibraryRefData": reply(200, path=F + "/refdata.json")
if method == "GET" and (r := m(r"/v1/appStoreVersionLocalizations/([^/]+)/placements", path)):
    if not os.path.exists(F + "/duo-ordered"): reply(200, path=f"{F}/placements-{r[1]}.json")
    ids = lines("duo-ordered")
    if os.path.exists(F + "/readback-drop"): ids = ids[:-1]
    placed = dict(l.split("=") for l in lines("duo-placed"))
    reply(200, {"data": [{"type": "appAssetLibraryPlacements", "id": i,
                          "attributes": {"placementGroup": "IPHONE_DUO_PROFILE", "state": "ACTIVE"},
                          "relationships": {"image": {"data": {"type": "appAssetLibraryImages", "id": placed[i]}}}} for i in ids],
                "included": [{"type": "appAssetLibraryImages", "id": placed[i], "attributes": {
                                  "fileName": open(f"{F}/image-{placed[i]}").read().strip(),
                                  "imageAsset": dict(zip(("width", "height"), image_dims(placed[i])))}} for i in ids]})
if method == "DELETE" and m(r"/v1/appAssetLibraryPlacements/[\w-]+", path): reply(204)
if method == "POST" and path == "/v1/appAssetLibraryImages":
    req = json.load(open(data[1:]))["data"]
    size = req["attributes"]["fileSize"]
    image_id = f"img-{len(lines('duo-images')) + 1}"
    open(F + "/duo-images", "a").write(image_id + "\n")
    open(f"{F}/image-{image_id}", "w").write(req["attributes"]["fileName"])
    half = size // 2
    ops = [{"method": "PUT", "url": f"https://upload.example.invalid/{image_id}/a", "offset": 0, "length": half,
            "requestHeaders": [{"name": "Content-Type", "value": "image/png"}]},
           {"method": "PUT", "url": f"https://upload.example.invalid/{image_id}/b", "offset": half, "length": size - half,
            "requestHeaders": [{"name": "Content-Type", "value": "image/png"}]}]
    reply(201, {"data": {"type": "appAssetLibraryImages", "id": image_id,
                         "attributes": {"state": "AWAITING_UPLOAD", "uploadOperations": ops}}})
if method == "PATCH" and m(r"/v1/appAssetLibraryImages/[\w-]+", path): reply(200, {"data": {}})
if method == "GET" and (r := m(r"/v1/appAssetLibraryImages/([\w-]+)", path)):
    w, h = image_dims(r[1])
    reply(200, {"data": {"id": r[1], "attributes": {
        "state": open(F + "/duo-state").read().strip(), "stateDetails": [{"code": "IMAGE_TOOL_FAILURE"}],
        "imageAsset": {"width": w, "height": h,
                       "templateUrl": f"https://render.example.invalid/duo/{r[1]}/{{w}}x{{h}}bb.{{f}}"}}}})
if method == "GET" and (r := re.match(r"https://render\.example\.invalid/duo/([\w-]+)/", url or "")):
    # Rendered the way round the stored image is, unless a case overrides it.
    w, h = image_dims(r[1])
    way = open(F + "/duo-render").read().strip() if os.path.exists(F + "/duo-render") else ("landscape" if w > h else "portrait")
    reply(200, path=f"{F}/render-{way}.png")
if method == "POST" and path == "/v1/appAssetLibraryPlacements":
    req = json.load(open(data[1:]))["data"]
    placement_id = f"plc-{len(lines('duo-placed')) + 1}"
    open(F + "/duo-placed", "a").write(f"{placement_id}={req['relationships']['image']['data']['id']}\n")
    reply(201, {"data": {"type": "appAssetLibraryPlacements", "id": placement_id}})
if method == "POST" and path == "/v1/appAssetLibraryPlacementOrderingRequests":
    req = json.load(open(data[1:]))["data"]
    open(F + "/duo-ordered", "w").write("\n".join(p["id"] for p in req["relationships"]["orderedPlacements"]["data"]) + "\n")
    reply(201, {"data": {"type": "appAssetLibraryPlacementOrderingRequests", "id": "ord-1"}})
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
# The default is the two required sets. The Duo set's writes have never been
# sent to Apple, so nothing reaches even its reads unless it is asked for by
# name (cases 19 on).
! grep -q 'ssetLibrar\|/placements' "$TMP/w/calls.log" || fail "the default run reached the asset library: $(cat "$TMP/w/calls.log")"
! echo "$OUT" | grep -qi "duo" || fail "the default run mentioned the Duo set: $OUT"
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
echo "$OUT" | grep -q "retrying in 0s (server asked 7s)" || fail "Retry-After of 7 was not read, or not capped by API_RETRY_MAX_SLEEP=0: $OUT"
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

# 17. Retry-After may be an HTTP-date. It is converted to seconds from now,
#     not treated as garbage and replaced by the 30s fallback -- which could
#     spend every retry before the window reopens.
setup; echo "1 POST https://api.appstoreconnect.apple.com/v1/appScreenshots" > "$TMP/w/fix/rate429"
python3 -c 'import email.utils, time; print(email.utils.formatdate(time.time() + 20, usegmt=True))' > "$TMP/w/fix/retry-after"
run --apply --device iphone
[ "$RC" = 0 ] || fail "an HTTP-date Retry-After failed the run: $OUT"
echo "$OUT" | grep -qE "server asked (1[5-9]|2[01])s" || fail "HTTP-date not converted to ~20s: $OUT"
pass "HTTP-date Retry-After converted to seconds"

# 17b. An unusable Retry-After falls back to 30s, still under the cap.
setup; echo "1 POST https://api.appstoreconnect.apple.com/v1/appScreenshots" > "$TMP/w/fix/rate429"
echo "soon, probably" > "$TMP/w/fix/retry-after"; run --apply --device iphone
[ "$RC" = 0 ] || fail "an unparseable Retry-After failed the run: $OUT"
echo "$OUT" | grep -q "server asked nothing" || fail "unparseable Retry-After not reported as such: $OUT"
pass "unparseable Retry-After falls back"

# 18. A non-integer knob is refused before any call: as a comparison operand
#     it errors instead of answering, and the retry loop would never stop.
for knob in API_RETRIES=many API_RETRY_MAX_SLEEP=-1 UPLOAD_POLL_DELAY=1.5 UPLOAD_POLL_ATTEMPTS=0; do
    setup
    set +e
    OUT="$(env PATH="$TMP/w/bin:/usr/bin:/bin" ASC_JWT="$TMP/w/jwt" SCREENSHOTS_DIR="$TMP/w/shots" \
        ASC_APP_ID=APP "$knob" "$SCRIPT" --version 1.2 2>&1)"; RC=$?
    set -e
    [ "$RC" != 0 ] || fail "accepted $knob"
    [ ! -s "$TMP/w/calls.log" ] || fail "made network calls with $knob"
    echo "$OUT" | grep -q "${knob%%=*}" || fail "did not name the bad knob $knob: $OUT"
done
pass "non-integer or out-of-range knobs refused"

# ---- the iPhone Duo set (issue #409) ---------------------------------------
# A Duo screenshot is not in an appScreenshotSet: it is an asset-library image
# placed in the group IPHONE_DUO_PROFILE on the version's localization.

duo_mutations() { grep -cE '^(POST|PATCH|DELETE|PUT) ' "$TMP/w/calls.log" || true; }

# 19. The Duo dry run lists every file with its size and the group it would
#     go to, and writes nothing. It also leaves the screenshot sets unread:
#     it could not change what it never resolved.
setup; run --device duo
[ "$RC" = 0 ] || fail "duo dry run exited $RC: $OUT"
[ "$(duo_mutations)" = 0 ] || fail "duo dry run made mutating calls: $(cat "$TMP/w/calls.log")"
echo "$OUT" | grep -q "dry run" || fail "duo dry run did not say so: $OUT"
for s in $SLOTS; do
    echo "$OUT" | grep -q "iphone-duo/$s.png 2034x1398 -> APP_SCREENSHOT in IPHONE_DUO_PROFILE" \
        || fail "duo dry run did not list $s with its size and group: $OUT"
done
! grep -q 'appScreenshot' "$TMP/w/calls.log" || fail "duo dry run read a screenshot set: $(cat "$TMP/w/calls.log")"
pass "duo dry run lists every file and its placement group, and mutates nothing"

# 20. The Duo happy path. Pins: the version's old placements deleted before
#     the first reservation (the group's limit of 10); each image created in
#     the app's library as a screenshot, uploaded whole and committed; each
#     placed in the Duo group on THIS version's localization; the order
#     pinned; and no image ever deleted, since another version may share it.
setup; run --apply --device duo
[ "$RC" = 0 ] || fail "duo apply exited $RC: $OUT"
first_post="$(grep -n '^POST ' "$TMP/w/calls.log" | head -1 | cut -d: -f1)"
last_delete="$(grep -n '^DELETE ' "$TMP/w/calls.log" | tail -1 | cut -d: -f1)"
[ -n "$last_delete" ] && [ "$last_delete" -lt "$first_post" ] || fail "a duo reservation came before the last delete"
[ "$(grep -c '^DELETE .*/v1/appAssetLibraryPlacements/oldp-[12] ' "$TMP/w/calls.log")" = 2 ] || fail "did not delete both old Duo placements"
[ "$(grep -c '^DELETE ' "$TMP/w/calls.log")" = 2 ] || fail "deleted something other than the two old placements"
! grep -q '^DELETE .*/v1/appAssetLibraryImages/' "$TMP/w/calls.log" || fail "deleted a library image"
[ "$(grep -c '^POST .*/v1/appAssetLibraryImages ' "$TMP/w/calls.log")" = 6 ] || fail "expected 6 image reservations"
[ "$(grep -c '^PUT https://upload' "$TMP/w/calls.log")" = 12 ] || fail "expected 12 duo part uploads (2 per shot)"
[ "$(grep -cE '^PATCH .*/v1/appAssetLibraryImages/img-[1-6] ' "$TMP/w/calls.log")" = 6 ] || fail "expected 6 duo upload commits"
[ "$(grep -c '^POST .*/v1/appAssetLibraryPlacements ' "$TMP/w/calls.log")" = 6 ] || fail "expected 6 placements"
python3 - "$TMP/w/calls.log" <<'PY' || fail "a Duo request body is not what Apple's schema asks for (see above)"
import json, sys
bodies = [json.loads(l[5:])["data"] for l in open(sys.argv[1]) if l.startswith("BODY ")]
images = [b for b in bodies if b["type"] == "appAssetLibraryImages" and "id" not in b]
commits = [b for b in bodies if b["type"] == "appAssetLibraryImages" and "id" in b]
places = [b for b in bodies if b["type"] == "appAssetLibraryPlacements"]
orders = [b for b in bodies if b["type"] == "appAssetLibraryPlacementOrderingRequests"]
slots = "05-ingame 01-play-tab 02-library 03-preset-editor 06-automap 04-control-feel".split()
assert [b["attributes"]["fileName"] for b in images] == [f"iphone-duo-{s}.png" for s in slots], images
for b in images:
    assert b["attributes"]["category"] == "APP_SCREENSHOTS_AND_PREVIEWS", b
    assert b["attributes"]["fileSize"] > 0, b
    assert b["relationships"]["assetLibrary"]["data"] == {"type": "appAssetLibraries", "id": "LIB"}, b
assert [(b["id"], b["attributes"]) for b in commits] == [(f"img-{n}", {"uploaded": True}) for n in range(1, 7)], commits
for n, b in enumerate(places, 1):
    assert b["attributes"] == {"placementType": "APP_SCREENSHOT", "placementGroup": "IPHONE_DUO_PROFILE"}, b
    assert b["relationships"]["image"]["data"] == {"type": "appAssetLibraryImages", "id": f"img-{n}"}, b
    assert b["relationships"]["appStoreVersionLocalization"]["data"] == {"type": "appStoreVersionLocalizations", "id": "L12"}, b
assert len(orders) == 1, orders
assert orders[0]["attributes"] == {"placementGroup": "IPHONE_DUO_PROFILE"}, orders
assert [p["id"] for p in orders[0]["relationships"]["orderedPlacements"]["data"]] == [f"plc-{n}" for n in range(1, 7)], orders
assert orders[0]["relationships"]["appStoreVersionLocalization"]["data"]["id"] == "L12", orders
PY
! grep -q 'appScreenshot' "$TMP/w/calls.log" || fail "duo apply touched a screenshot set"
echo "$OUT" | grep -q "plc-1 ACTIVE iphone-duo-05-ingame.png 2034x1398" || fail "duo apply did not print the read-back: $OUT"
echo "$OUT" | grep -q "6 screenshots placed in IPHONE_DUO_PROFILE" || fail "duo apply did not report success: $OUT"
pass "duo apply deletes old placements first, uploads, places, orders and reads back"

# 20b. The Duo part uploads carry exactly the file's bytes.
size="$(wc -c < "$TMP/w/shots/iphone-duo/05-ingame.png" | tr -d ' ')"
parts="$(grep '^PUT https://upload.example.invalid/img-1/' "$TMP/w/calls.log" | awk '{ s += $3 } END { print s }')"
[ "$parts" = "$size" ] || fail "uploaded $parts bytes of a $size-byte duo file"
pass "duo part uploads sum to the file size"

# 21. A Duo file of a wrong size is refused before any network call. Two
#     wrong sizes: one that is nobody's, and the 6.9" iPhone's, which is a
#     real store size and the likeliest file to land in the wrong directory.
for wrong in "2034 1400" "2868 1320"; do
    setup; make_png "$TMP/w/shots/iphone-duo/02-library.png" $wrong; run --apply --device duo
    [ "$RC" != 0 ] || fail "accepted a Duo file of size $wrong"
    [ ! -s "$TMP/w/calls.log" ] || fail "made network calls despite a wrongly-sized Duo file ($wrong)"
    echo "$OUT" | grep -q "exactly one of" || fail "wrong failure for size $wrong: $OUT"
done
pass "wrong Duo size refused locally"

# 22. So is a Duo file carrying an eXIf chunk.
setup; make_png "$TMP/w/shots/iphone-duo/06-automap.png" 2034 1398 exif; run --apply --device duo
[ "$RC" != 0 ] || fail "accepted a Duo PNG with eXIf"
[ ! -s "$TMP/w/calls.log" ] || fail "made network calls despite an eXIf Duo file"
echo "$OUT" | grep -q "eXIf" || fail "wrong failure: $OUT"
pass "eXIf chunk refused locally in the Duo set"

# 23. A version waiting for review, or in it, gets no Duo write: whether a
#     new placement edits that submission or pulls it from review is not
#     known, and this is not the place to find out.
for state in WAITING_FOR_REVIEW IN_REVIEW; do
    setup; sed -i.bak "s/\"PREPARE_FOR_SUBMISSION\"/\"$state\"/" "$TMP/w/fix/versions.json"; run --apply --device duo
    [ "$RC" != 0 ] || fail "placed Duo screenshots on a version in $state"
    [ "$(duo_mutations)" = 0 ] || fail "mutated a version in $state: $(cat "$TMP/w/calls.log")"
    echo "$OUT" | grep -q "cannot be edited" || fail "wrong refusal for $state: $OUT"
    # The refusal still says what was asked for: the file list is local.
    echo "$OUT" | grep -q "iphone-duo/05-ingame.png 2034x1398 -> APP_SCREENSHOT in IPHONE_DUO_PROFILE" \
        || fail "a refused run did not list the Duo files: $OUT"
done
pass "Duo set refused on a version waiting for or in review"

# 24. All four sizes are accepted, mixed in one set, and each is checked the
#     way round it is: a portrait file must render portrait.
setup
make_png "$TMP/w/shots/iphone-duo/05-ingame.png" 1398 2034
make_png "$TMP/w/shots/iphone-duo/01-play-tab.png" 2853 2007
make_png "$TMP/w/shots/iphone-duo/02-library.png" 2007 2853
run --apply --device duo
[ "$RC" = 0 ] || fail "a mixed-size Duo set failed: $OUT"
echo "$OUT" | grep -q "uploaded iphone-duo/05-ingame .*1398 2034, portrait" || fail "portrait Duo shot not reported as portrait: $OUT"
echo "$OUT" | grep -q "uploaded iphone-duo/01-play-tab .*2853 2007, landscape" || fail "inner-display shot not accepted: $OUT"
pass "all four Duo sizes accepted, portrait verified as portrait"

# 25. Stored transposed, or rendered the wrong way round, fails -- in both
#     directions, since a Duo shot may legitimately be either.
setup; echo "1398 2034" > "$TMP/w/fix/duo-dims"; run --apply --device duo
[ "$RC" != 0 ] || fail "accepted transposed Duo dimensions"
echo "$OUT" | grep -q "transposed" || fail "wrong failure: $OUT"
setup; echo "portrait" > "$TMP/w/fix/duo-render"; run --apply --device duo
[ "$RC" != 0 ] || fail "accepted a landscape Duo shot rendered portrait"
echo "$OUT" | grep -q "stored sideways" || fail "wrong failure: $OUT"
setup; for s in $SLOTS; do make_png "$TMP/w/shots/iphone-duo/$s.png" 1398 2034; done
echo "landscape" > "$TMP/w/fix/duo-render"; run --apply --device duo
[ "$RC" != 0 ] || fail "accepted a portrait Duo shot rendered landscape"
echo "$OUT" | grep -q "stored sideways" || fail "wrong failure: $OUT"
[ "$(grep -c '^POST .*/v1/appAssetLibraryPlacements ' "$TMP/w/calls.log")" = 0 ] || fail "placed an image that failed its check"
pass "sideways Duo store fails before the image is placed"

# 26. Apple rejecting the image fails the run, and nothing is placed.
setup; echo "FAILED" > "$TMP/w/fix/duo-state"; run --apply --device duo
[ "$RC" != 0 ] || fail "accepted a FAILED Duo image"
echo "$OUT" | grep -q "rejected iphone-duo/05-ingame" || fail "wrong failure: $OUT"
echo "$OUT" | grep -q "IMAGE_TOOL_FAILURE" || fail "did not show Apple's state details: $OUT"
[ "$(grep -c '^POST .*/v1/appAssetLibraryPlacements ' "$TMP/w/calls.log")" = 0 ] || fail "placed a FAILED image"
pass "FAILED Duo image fails"

# 26b. An image that never leaves processing is a failure too, not a wait
#      without end.
setup; echo "UPLOAD_COMPLETE" > "$TMP/w/fix/duo-state"; run --apply --device duo
[ "$RC" != 0 ] || fail "accepted an image that never finished processing"
echo "$OUT" | grep -q "still UPLOAD_COMPLETE after 3 polls" || fail "wrong failure: $OUT"
pass "Duo image stuck in processing fails after the poll limit"

# 27. A placement listed for the version that names another localization is
#     never deleted: that would be another version's screenshot.
setup; sed -i.bak 's/"id":"L12"}}}},/"id":"L11"}}}},/' "$TMP/w/fix/placements-L12.json"; run --apply --device duo
[ "$RC" != 0 ] || fail "accepted a placement of another localization"
[ "$(duo_mutations)" = 0 ] || fail "mutated after finding a foreign placement"
echo "$OUT" | grep -q "oldp-1 .*refusing to touch it" || fail "wrong refusal: $OUT"
pass "placement of another localization refused"

# 28. The slot is taken from Apple's reference data, not assumed: a group
#     that is gone, or a size it no longer lists, stops the run before any
#     write.
setup; sed -i.bak 's/"placementGroupId":"IPHONE_DUO_PROFILE"/"placementGroupId":"IPHONE_FOLD_PROFILE"/' "$TMP/w/fix/refdata.json"; run --apply --device duo
[ "$RC" != 0 ] || fail "uploaded to a group the reference data does not offer"
[ "$(duo_mutations)" = 0 ] || fail "mutated without the group in the reference data"
echo "$OUT" | grep -q "no image spec is mapped to IPHONE_DUO_PROFILE" || fail "wrong failure: $OUT"
setup; sed -i.bak 's/"specs":\["spec-ol",/"specs":[/' "$TMP/w/fix/refdata.json"; run --apply --device duo
[ "$RC" != 0 ] || fail "uploaded a size the reference data does not list"
[ "$(duo_mutations)" = 0 ] || fail "mutated with a size the reference data does not list"
echo "$OUT" | grep -q "lists no 2034x1398 spec" || fail "wrong failure: $OUT"
setup; sed -i.bak 's/"maxCount":10/"maxCount":5/' "$TMP/w/fix/refdata.json"; run --apply --device duo
[ "$RC" != 0 ] || fail "uploaded six into a group limited to five"
[ "$(duo_mutations)" = 0 ] || fail "mutated past the group limit"
pass "reference data decides the group, the sizes and the limit"

# 29. A failed listing of the version's placements fails closed: it decides
#     what gets deleted, and an error must never read as "none".
setup; echo "appStoreVersionLocalizations/L12/placements" > "$TMP/w/fix/fail"; run --apply --device duo
[ "$RC" != 0 ] || fail "treated a failed placement listing as empty"
[ "$(duo_mutations)" = 0 ] || fail "mutated after a failed placement listing"
echo "$OUT" | grep -q "HTTP 500" || fail "did not surface the status: $OUT"
pass "failed placement listing fails closed"

# 30. The 201s are not the evidence; the read-back is. If the group read
#     back is not the six just placed, in order, the run fails.
setup; : > "$TMP/w/fix/readback-drop"; run --apply --device duo
[ "$RC" != 0 ] || fail "accepted a read-back that is missing a placement"
echo "$OUT" | grep -q "read back are not the 6 just placed" || fail "wrong failure: $OUT"
pass "read-back mismatch fails"

# 31. The Duo writes have never been sent to Apple, so a routine upload must
#     not reach them: `--device all`, and no --device at all, replace the two
#     required sets and make no asset-library call of any kind, read or
#     write. This holds even when the Duo directory is broken, because the
#     Duo files are not looked at either.
for args in "--device all" ""; do
    setup; echo "2752 2064" > "$TMP/w/fix/dims-S12I"
    make_png "$TMP/w/shots/iphone-duo/05-ingame.png" 10 10 exif
    # shellcheck disable=SC2086
    run --apply $args
    [ "$RC" = 0 ] || fail "apply of the two required sets (${args:-no --device}) exited $RC: $OUT"
    [ "$(grep -c '^POST .*/v1/appScreenshots ' "$TMP/w/calls.log")" = 12 ] || fail "expected 12 set reservations (${args:-no --device})"
    ! grep -q 'ssetLibrar\|/placements' "$TMP/w/calls.log" \
        || fail "a routine upload (${args:-no --device}) reached the asset library: $(grep 'ssetLibrar\|/placements' "$TMP/w/calls.log")"
    ! echo "$OUT" | grep -qi "duo" || fail "a routine upload (${args:-no --device}) mentioned the Duo set: $OUT"
done
pass "--device all and the default upload the two required sets and never touch the Duo set"

# 31b. And there is no spelling that uploads the Duo set together with the
#      others: its checks run before any write, so in one run a Duo refusal
#      would stop the required sets. It runs alone or not at all.
for combo in "iphone,duo" "all,duo" "iphone duo" "everything"; do
    setup; run --apply --device "$combo"
    [ "$RC" = 2 ] || fail "--device '$combo' was accepted (exit $RC): $OUT"
    [ ! -s "$TMP/w/calls.log" ] || fail "--device '$combo' made network calls"
done
pass "the Duo set cannot be combined with another set"

echo "All upload-screenshots tests passed."
