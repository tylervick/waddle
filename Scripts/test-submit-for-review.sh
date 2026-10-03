#!/bin/bash
# Tests for Scripts/submit-for-review.sh.
#
# HERMETIC: curl is a strict, stateful stub on a controlled PATH -- the PATCH
# that marks a submission submitted changes what the read-back GET returns,
# so the state check is really exercised. The JWT comes from a fake ASC_JWT.
# Nothing here contacts App Store Connect.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

SCRIPT="$ROOT/Scripts/submit-for-review.sh"

setup() {
    rm -rf "$TMP/w"; mkdir -p "$TMP/w/bin" "$TMP/w/fix"
    F="$TMP/w/fix"
    cat > "$F/versions.json" <<'JSON'
{"data":[
 {"id":"V13","attributes":{"versionString":"1.3","appVersionState":"PREPARE_FOR_SUBMISSION"}},
 {"id":"V12","attributes":{"versionString":"1.2","appVersionState":"READY_FOR_DISTRIBUTION"}}]}
JSON
    echo '{"data":{"id":"B277","attributes":{"version":"277"}}}' > "$F/build.json"
    echo '{"data":{"type":"apps","id":"APP","attributes":{"contentRightsDeclaration":"USES_THIRD_PARTY_CONTENT"}}}' > "$F/app.json"
    echo '{"data":{"type":"betaLicenseAgreements","id":"BLA","attributes":{"agreementText":null}}}' > "$F/beta.json"
    : > "$F/eula.404"                       # present = the relationship is unset (404)
    echo '{"data":[]}' > "$F/submissions.json"
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
p = (url or "").replace("https://api.appstoreconnect.apple.com", "").split("?")[0]
m = re.fullmatch
if method == "GET" and m(r"/v1/apps/[^/]+/appStoreVersions", p): reply(200, path=F + "/versions.json")
if method == "GET" and p == "/v1/appStoreVersions/V13/build": reply(200, path=F + "/build.json")
if method == "GET" and m(r"/v1/apps/[^/]+", p): reply(200, path=F + "/app.json")
if method == "GET" and m(r"/v1/apps/[^/]+/betaLicenseAgreement", p): reply(200, path=F + "/beta.json")
if method == "GET" and m(r"/v1/apps/[^/]+/endUserLicenseAgreement", p):
    if os.path.exists(F + "/eula.404"): reply(404, {"errors": [{"status": "404", "code": "NOT_FOUND"}]})
    reply(200, path=F + "/eula.json")
if method == "GET" and m(r"/v1/apps/[^/]+/reviewSubmissions", p): reply(200, path=F + "/submissions.json")
if method == "POST" and p == "/v1/reviewSubmissions":
    json.dump({"data": {"type": "reviewSubmissions", "id": "RS1", "attributes": {"state": "READY_FOR_REVIEW", "submitted": False}}}, open(F + "/rs.json", "w"))
    reply(201, path=F + "/rs.json")
if method == "POST" and p == "/v1/reviewSubmissionItems":
    reply(201, {"data": {"type": "reviewSubmissionItems", "id": "RSI1"}})
if method == "PATCH" and p == "/v1/reviewSubmissions/RS1":
    doc = json.load(open(F + "/rs.json"))
    if json.loads(body)["data"]["attributes"].get("submitted"):
        doc["data"]["attributes"]["submitted"] = True
        doc["data"]["attributes"]["state"] = open(F + "/state-after-submit").read().strip() if os.path.exists(F + "/state-after-submit") else "WAITING_FOR_REVIEW"
    json.dump(doc, open(F + "/rs.json", "w")); reply(200, path=F + "/rs.json")
if method == "GET" and p == "/v1/reviewSubmissions/RS1": reply(200, path=F + "/rs.json")
sys.stderr.write(f"stub curl: unhandled {method} {url}\n"); sys.exit(64)
STUB
    chmod +x "$TMP/w/bin/curl"
    printf '#!/bin/bash\necho fake.jwt.token\n' > "$TMP/w/jwt"; chmod +x "$TMP/w/jwt"
    : > "$TMP/w/calls.log"
}

run() { # args... -- exit status in RC, combined output in OUT
    set +e
    OUT="$(env PATH="$TMP/w/bin:/usr/bin:/bin" ASC_JWT="$TMP/w/jwt" ASC_APP_ID=APP API_RETRY_MAX_SLEEP=0 GITHUB_ACTIONS= \
        "$SCRIPT" --version 1.3 "$@" 2>&1)"
    RC=$?
    set -e
}
mutations() { grep -cE '^(POST|PATCH|DELETE|PUT) ' "$TMP/w/calls.log" || true; }

# 1. The dry run re-reads every gate, says what it would submit, and sends
#    nothing.
setup; run
[ "$RC" = 0 ] || fail "dry run exited $RC: $OUT"
[ "$(mutations)" = 0 ] || fail "dry run wrote: $(cat "$TMP/w/calls.log")"
echo "$OUT" | grep -q "ok - build 277 is selected" || fail "build not reported: $OUT"
echo "$OUT" | grep -q "ok - content rights: USES_THIRD_PARTY_CONTENT" || fail "content rights not reported: $OUT"
echo "$OUT" | grep -q "ok - licence agreements: both empty" || fail "licence check not reported: $OUT"
echo "$OUT" | grep -q "would submit version 1.3 (build 277)" || fail "dry run did not say what it would submit: $OUT"
pass "dry run checks every gate and submits nothing"

# 2. Apply creates the submission, adds the version, marks it submitted, and
#    confirms from the read-back state.
setup; run --apply
[ "$RC" = 0 ] || fail "apply exited $RC: $OUT"
grep -q '^POST .*/v1/reviewSubmissions$' "$TMP/w/calls.log" || fail "submission not created"
grep -A1 '^POST .*/v1/reviewSubmissions$' "$TMP/w/calls.log" | grep -q '"id": "APP"' || fail "submission not related to the app"
grep -A1 '^POST .*/v1/reviewSubmissionItems$' "$TMP/w/calls.log" | grep -q '"id": "V13"' || fail "version not added to the submission"
grep -A1 '^PATCH .*/v1/reviewSubmissions/RS1' "$TMP/w/calls.log" | grep -q '"submitted": true' || fail "submission not marked submitted"
echo "$OUT" | grep -q "ok - submitted: version 1.3 (build 277) is WAITING_FOR_REVIEW" || fail "no read-back confirmation: $OUT"
pass "apply submits and confirms from the read-back state"

# 3. A read-back that is not waiting for review is reported as such, never
#    as success.
setup; echo "READY_FOR_REVIEW" > "$TMP/w/fix/state-after-submit"; run --apply
[ "$RC" != 0 ] || fail "reported success for a submission that did not submit"
echo "$OUT" | grep -q "reads READY_FOR_REVIEW rather than WAITING_FOR_REVIEW" || fail "wrong failure: $OUT"
pass "a submission that did not reach WAITING_FOR_REVIEW is a failure"

# 4. No build selected: refuse before any write.
setup; echo '{"data":null}' > "$TMP/w/fix/build.json"; run --apply
[ "$RC" != 0 ] || fail "submitted a version with no build"
[ "$(mutations)" = 0 ] || fail "wrote with no build: $(cat "$TMP/w/calls.log")"
echo "$OUT" | grep -q "has no build selected" || fail "wrong refusal: $OUT"
pass "no build refused before any write"

# 5. Content rights unanswered: refuse.
setup; echo '{"data":{"type":"apps","id":"APP","attributes":{"contentRightsDeclaration":null}}}' > "$TMP/w/fix/app.json"; run --apply
[ "$RC" != 0 ] || fail "submitted with content rights unanswered"
[ "$(mutations)" = 0 ] || fail "wrote with content rights unanswered"
echo "$OUT" | grep -q "content-rights declaration is unanswered" || fail "wrong refusal: $OUT"
pass "unanswered content rights refused"

# 6. A beta licence text, or a custom EULA relationship, is metadata.md §14's
#    "reconcile before submitting": refuse on either.
setup; echo '{"data":{"type":"betaLicenseAgreements","id":"BLA","attributes":{"agreementText":"Custom terms."}}}' > "$TMP/w/fix/beta.json"; run --apply
[ "$RC" != 0 ] || fail "submitted with a beta licence text set"
[ "$(mutations)" = 0 ] || fail "wrote with a beta licence text set"
echo "$OUT" | grep -q "betaLicenseAgreement.agreementText is set" || fail "wrong refusal: $OUT"
setup; rm "$TMP/w/fix/eula.404"; echo '{"data":{"type":"endUserLicenseAgreements","id":"EULA1","attributes":{"agreementText":"Custom."}}}' > "$TMP/w/fix/eula.json"; run --apply
[ "$RC" != 0 ] || fail "submitted with a custom EULA set"
[ "$(mutations)" = 0 ] || fail "wrote with a custom EULA set"
echo "$OUT" | grep -q "custom endUserLicenseAgreement (EULA1) is set" || fail "wrong refusal: $OUT"
pass "a set licence field refuses (both fields)"

# 7. An open review submission already on the app: refuse rather than reuse.
setup; echo '{"data":[{"id":"RS0","attributes":{"state":"READY_FOR_REVIEW"}}]}' > "$TMP/w/fix/submissions.json"; run --apply
[ "$RC" != 0 ] || fail "submitted alongside an open submission"
[ "$(mutations)" = 0 ] || fail "wrote alongside an open submission"
echo "$OUT" | grep -q "already has an open review submission (RS0:READY_FOR_REVIEW)" || fail "wrong refusal: $OUT"
pass "an open submission refuses"

# 8. A version that is not in a submittable state is refused (shared resolver).
setup; sed -i.bak 's/"PREPARE_FOR_SUBMISSION"/"WAITING_FOR_REVIEW"/' "$TMP/w/fix/versions.json"; run --apply
[ "$RC" != 0 ] || fail "submitted a version already in review"
[ "$(mutations)" = 0 ] || fail "wrote to a version in review"
echo "$OUT" | grep -q "its submission cannot be edited" || fail "wrong refusal: $OUT"
pass "non-submittable version refused"

# 9. A failed read fails closed: a 500 on the EULA read is not "empty".
setup; echo "GET https://api.appstoreconnect.apple.com/v1/apps/APP/endUserLicenseAgreement" > "$TMP/w/fix/fail"; run --apply
[ "$RC" != 0 ] || fail "treated a failed EULA read as empty"
[ "$(mutations)" = 0 ] || fail "wrote after a failed read"
echo "$OUT" | grep -q "HTTP 500" || fail "did not surface the status: $OUT"
pass "a failed read fails closed, 404 and 500 are not the same answer"

echo "All submit-for-review tests passed."
