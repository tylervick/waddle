#!/bin/bash
# Tests for Scripts/update-store-listing.sh (and the version resolution it
# shares with upload-screenshots.sh through Scripts/asc-api.sh).
#
# HERMETIC: curl is a strict, stateful stub on a controlled PATH -- a PATCH
# changes what the next GET returns, so the read-back verification is really
# exercised. The JWT comes from a fake ASC_JWT; the listing files are written
# per case. Nothing here contacts App Store Connect.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

SCRIPT="$ROOT/Scripts/update-store-listing.sh"

setup() {
    rm -rf "$TMP/w"; mkdir -p "$TMP/w/bin" "$TMP/w/fix" "$TMP/w/listing"
    L="$TMP/w/listing"; F="$TMP/w/fix"
    printf 'The new description.\n\nSecond paragraph.\n' > "$L/description.txt"
    printf 'What is new in 1.2.\n' > "$L/whats-new.txt"
    printf 'Promo text.\n' > "$L/promotional-text.txt"
    printf 'doom,wad\n' > "$L/keywords.txt"
    printf 'Notes for the reviewer.\n' > "$L/review-notes.txt"
    cat > "$F/versions.json" <<'JSON'
{"data":[
 {"id":"V12","attributes":{"versionString":"1.2","appVersionState":"PREPARE_FOR_SUBMISSION"}},
 {"id":"V11","attributes":{"versionString":"1.1","appVersionState":"READY_FOR_DISTRIBUTION"}}]}
JSON
    echo '{"data":[{"id":"L12","attributes":{"locale":"en-US"}}]}' > "$F/locs.json"
    # What App Store Connect holds now: description and What's New differ from
    # the repo, the rest already match.
    cat > "$F/loc.json" <<'JSON'
{"data":{"type":"appStoreVersionLocalizations","id":"L12","attributes":{
 "description":"The old description.","whatsNew":"What was new in 1.1.",
 "promotionalText":"Promo text.","keywords":"doom,wad","locale":"en-US"}}}
JSON
    echo '{"data":{"type":"appStoreReviewDetails","id":"R12","attributes":{"notes":"Notes for the reviewer."}}}' > "$F/review.json"
    cat > "$F/builds.json" <<'JSON'
{"data":[{"id":"B264","attributes":{"version":"264","processingState":"VALID","expired":false}}]}
JSON
    echo '{"data":{"id":"B262","attributes":{"version":"262"}}}' > "$F/current-build.json"

    cat > "$TMP/w/bin/curl" <<STUB
#!/usr/bin/env python3
import json, os, re, sys
F = "$F"
args = sys.argv[1:]
method, out, data, url, hdr = "GET", None, None, None, None
i = 0
while i < len(args):
    a = args[i]
    if a == "-X": method = args[i + 1]; i += 1
    elif a == "-o": out = args[i + 1]; i += 1
    elif a == "-D": hdr = args[i + 1]; i += 1
    elif a == "--data-binary": data = args[i + 1]; i += 1
    elif a in ("-H", "-w", "--connect-timeout", "--max-time"): i += 1
    elif a.startswith("http"): url = a
    i += 1
body = open(data[1:], encoding="utf-8").read() if data else ""
with open(F + "/../calls.log", "a", encoding="utf-8") as log:
    log.write(f"{method} {url}\n")
    if body: log.write(f"BODY {body}\n")
def reply(code, doc=None, path=None):
    if hdr: open(hdr, "w").write(f"HTTP/2 {code}\r\n\r\n")
    text = open(path, encoding="utf-8").read() if path else (json.dumps(doc) if doc is not None else "")
    if out: open(out, "w", encoding="utf-8").write(text)
    sys.stdout.write(str(code)); sys.exit(0)
fail = F + "/fail"
if os.path.exists(fail) and open(fail).read().strip() in f"{method} {url}":
    reply(500, {"errors": [{"status": "500", "detail": "injected"}]})
def merge(path, attrs):
    doc = json.load(open(path, encoding="utf-8"))
    ignore = open(F + "/ignore").read().split() if os.path.exists(F + "/ignore") else []
    for k, v in attrs.items():
        if k not in ignore: doc["data"]["attributes"][k] = v
    json.dump(doc, open(path, "w", encoding="utf-8"))
p = (url or "").replace("https://api.appstoreconnect.apple.com", "").split("?")[0]
m = re.fullmatch
if method == "GET" and m(r"/v1/apps/[^/]+/appStoreVersions", p): reply(200, path=F + "/versions.json")
if method == "GET" and m(r"/v1/appStoreVersions/V12/appStoreVersionLocalizations", p): reply(200, path=F + "/locs.json")
if method == "GET" and p == "/v1/appStoreVersionLocalizations/L12": reply(200, path=F + "/loc.json")
if method == "GET" and p == "/v1/appStoreVersions/V12/appStoreReviewDetail": reply(200, path=F + "/review.json")
if method == "GET" and p == "/v1/builds": reply(200, path=F + "/builds.json")
if method == "GET" and p == "/v1/appStoreVersions/V12/build": reply(200, path=F + "/current-build.json")
if method == "PATCH" and p == "/v1/appStoreVersionLocalizations/L12":
    merge(F + "/loc.json", json.loads(body)["data"]["attributes"]); reply(200, path=F + "/loc.json")
if method == "PATCH" and p == "/v1/appStoreReviewDetails/R12":
    merge(F + "/review.json", json.loads(body)["data"]["attributes"]); reply(200, path=F + "/review.json")
if method == "PATCH" and p == "/v1/appStoreVersions/V12/relationships/build":
    bid = json.loads(body)["data"]["id"]
    b = [x for x in json.load(open(F + "/builds.json"))["data"] if x["id"] == bid][0]
    json.dump({"data": {"id": bid, "attributes": {"version": b["attributes"]["version"]}}}, open(F + "/current-build.json", "w"))
    reply(204)
sys.stderr.write(f"stub curl: unhandled {method} {url}\n"); sys.exit(64)
STUB
    chmod +x "$TMP/w/bin/curl"
    printf '#!/bin/bash\necho fake.jwt.token\n' > "$TMP/w/jwt"; chmod +x "$TMP/w/jwt"
    : > "$TMP/w/calls.log"
}

run() { # args... -- exit status in RC, combined output in OUT
    set +e
    OUT="$(env PATH="$TMP/w/bin:/usr/bin:/bin" ASC_JWT="$TMP/w/jwt" LISTING_DIR="$TMP/w/listing" \
        ASC_APP_ID=APP API_RETRY_MAX_SLEEP=0 GITHUB_ACTIONS= \
        "$SCRIPT" --version 1.2 "$@" 2>&1)"
    RC=$?
    set -e
}
mutations() { grep -cE '^(POST|PATCH|DELETE|PUT) ' "$TMP/w/calls.log" || true; }
field() { # attr [file] -- the attribute as stored by the stub
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["attributes"][sys.argv[2]], end="")' \
        "${2:-$TMP/w/fix/loc.json}" "$1"
}

# 1. The default is a dry run: it shows what differs, as a diff, and writes
#    nothing. Unchanged fields say so, so a clean run reads as clean.
setup; run
[ "$RC" = 0 ] || fail "dry run exited $RC: $OUT"
[ "$(mutations)" = 0 ] || fail "dry run wrote: $(cat "$TMP/w/calls.log")"
echo "$OUT" | grep -q "description: differs" || fail "description difference not reported: $OUT"
echo "$OUT" | grep -q -- "-The old description." || fail "diff does not show the store's text: $OUT"
echo "$OUT" | grep -q "+The new description." || fail "diff does not show the repo's text: $OUT"
echo "$OUT" | grep -q "ok - promotionalText: unchanged" || fail "unchanged field not reported as such: $OUT"
echo "$OUT" | grep -q "dry run: nothing written" || fail "dry run did not say so: $OUT"
pass "dry run diffs and writes nothing"

# 2. Apply writes only the fields that differ, in one PATCH, then reads back
#    and confirms. A second run finds nothing to do.
setup; run --apply
[ "$RC" = 0 ] || fail "apply exited $RC: $OUT"
[ "$(grep -c '^PATCH .*/appStoreVersionLocalizations/L12' "$TMP/w/calls.log")" = 1 ] || fail "expected one localization PATCH"
grep '^BODY ' "$TMP/w/calls.log" | grep -q '"description"' || fail "description not written"
grep '^BODY ' "$TMP/w/calls.log" | grep -q '"whatsNew"' || fail "whatsNew not written"
! grep '^BODY ' "$TMP/w/calls.log" | grep -q '"promotionalText"' || fail "wrote an unchanged field"
! grep -q '^PATCH .*/appStoreReviewDetails/' "$TMP/w/calls.log" || fail "wrote unchanged review notes"
[ "$(field description)" = "$(printf 'The new description.\n\nSecond paragraph.')" ] || fail "description not stored exactly, without the file's trailing newline"
echo "$OUT" | grep -q "ok - App Store Connect matches the repo" || fail "no read-back confirmation: $OUT"
: > "$TMP/w/calls.log"; run --apply
[ "$RC" = 0 ] && [ "$(mutations)" = 0 ] || fail "second apply was not a no-op: $OUT"
pass "apply writes only what differs, verifies, and converges"

# 3. Text that would break hand-built JSON round-trips exactly: quotes,
#    backslashes, a tab, non-ASCII, blank-line paragraphs.
setup
printf 'She said "go" \\ then\ttabbed. Café – naïve.\n\nNext.\n' > "$TMP/w/listing/review-notes.txt"
run --apply
[ "$RC" = 0 ] || fail "apply with awkward text exited $RC: $OUT"
[ "$(field notes "$TMP/w/fix/review.json")" = "$(printf 'She said "go" \\ then\ttabbed. Café – naïve.\n\nNext.')" ] \
    || fail "review notes not stored byte-for-byte: $(field notes "$TMP/w/fix/review.json")"
pass "quotes, backslashes, tabs and non-ASCII round-trip exactly"

# 4. Apple's limits are checked locally, in characters, before any call.
setup; python3 -c 'print("x" * 171)' > "$TMP/w/listing/promotional-text.txt"; run
[ "$RC" != 0 ] || fail "accepted 171 characters of promotional text"
[ ! -s "$TMP/w/calls.log" ] || fail "made calls with an over-limit file"
echo "$OUT" | grep -q "allows 170 for promotionalText" || fail "wrong refusal: $OUT"
# ...in characters, not bytes: 170 accented letters is 340 bytes and fine.
setup; python3 -c 'print("é" * 170)' > "$TMP/w/listing/promotional-text.txt"; run
[ "$RC" = 0 ] || fail "counted bytes, not characters: $OUT"
pass "length limits checked in characters, before any call"

# 5. An empty field is refused: clearing a store field should be deliberate.
setup; : > "$TMP/w/listing/keywords.txt"; run
[ "$RC" != 0 ] || fail "accepted an empty keywords file"
[ ! -s "$TMP/w/calls.log" ] || fail "made calls with an empty file"
pass "empty file refused"

# 6. A version that is not editable is refused before any write.
setup; sed -i.bak 's/"PREPARE_FOR_SUBMISSION"/"WAITING_FOR_REVIEW"/' "$TMP/w/fix/versions.json"; run --apply
[ "$RC" != 0 ] || fail "wrote to a version in review"
[ "$(mutations)" = 0 ] || fail "mutated a non-editable version"
echo "$OUT" | grep -q "its listing cannot be edited" || fail "wrong refusal: $OUT"
pass "non-editable version refused"

# 7. A missing version names the versions that do exist -- the first real
#    dry run failed on exactly this, and the bare message sent a human to
#    App Store Connect to find out why.
setup; run --version 1.3
[ "$RC" != 0 ] || fail "accepted a version that does not exist"
echo "$OUT" | grep -q "1.1 (READY_FOR_DISTRIBUTION)" || fail "did not list the versions it found: $OUT"
pass "missing version lists what exists"

# 8. --build selects a processed build of this version, and is verified.
setup; run --build 264
[ "$RC" = 0 ] || fail "dry run with --build exited $RC: $OUT"
echo "$OUT" | grep -q "build: would change from 262 to 264" || fail "build change not reported: $OUT"
[ "$(mutations)" = 0 ] || fail "dry run selected a build"
run --apply --build 264
[ "$RC" = 0 ] || fail "apply with --build exited $RC: $OUT"
grep -q '^PATCH .*/appStoreVersions/V12/relationships/build' "$TMP/w/calls.log" || fail "build not selected"
echo "$OUT" | grep -q "build 264 selected" || fail "build selection not confirmed: $OUT"
pass "build selected and verified"

# 9. A build still processing is refused before ANY write -- text included,
#    so a half-applied run cannot happen on this path.
setup; sed -i.bak 's/"VALID"/"PROCESSING"/' "$TMP/w/fix/builds.json"; run --apply --build 264
[ "$RC" != 0 ] || fail "selected a build still processing"
[ "$(mutations)" = 0 ] || fail "wrote text before refusing the build"
echo "$OUT" | grep -q "wait for processing" || fail "wrong refusal: $OUT"
pass "unprocessed build refused before any write"

# 10. So is a build number that does not belong to this version.
setup; echo '{"data":[]}' > "$TMP/w/fix/builds.json"; run --apply --build 999
[ "$RC" != 0 ] || fail "accepted a build that does not exist"
[ "$(mutations)" = 0 ] || fail "wrote before refusing a missing build"
pass "unknown build refused"

# 11. A write that App Store Connect accepts but does not keep is caught by
#     the read-back, not reported as success.
setup; echo "whatsNew" > "$TMP/w/fix/ignore"; run --apply
[ "$RC" != 0 ] || fail "reported success for a write that did not stick"
echo "$OUT" | grep -q "whatsNew on App Store Connect does not match" || fail "wrong failure: $OUT"
pass "read-back catches a write that did not stick"

# 12. A failed read fails closed; it is never taken as "empty, so differs".
setup; echo "GET https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations/L12" > "$TMP/w/fix/fail"; run --apply
[ "$RC" != 0 ] || fail "treated a failed read as an answer"
[ "$(mutations)" = 0 ] || fail "wrote after a failed read"
echo "$OUT" | grep -q "HTTP 500" || fail "did not surface the status: $OUT"
pass "failed read fails closed"

# 13. No App Review detail: refuse, rather than create one without the
#     reviewer contact details only the UI collects.
setup; echo '{"data":null}' > "$TMP/w/fix/review.json"; run --apply
[ "$RC" != 0 ] || fail "carried on without an App Review detail"
[ "$(mutations)" = 0 ] || fail "wrote without an App Review detail"
pass "missing App Review detail refused"

# 14. CRLF from App Store Connect is the same text, not a difference.
setup
python3 - "$TMP/w/fix/loc.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["data"]["attributes"]["description"] = "The new description.\r\n\r\nSecond paragraph."
d["data"]["attributes"]["whatsNew"] = "What is new in 1.2."
json.dump(d, open(sys.argv[1], "w"))
PY
run
echo "$OUT" | grep -q "ok - description: unchanged" || fail "CRLF counted as a difference: $OUT"
pass "CRLF line endings compare equal"

echo "All update-store-listing tests passed."
