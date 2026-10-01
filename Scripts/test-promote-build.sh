#!/bin/bash
# Tests for Scripts/promote-build.sh.
#
# Fully HERMETIC, in the manner of Scripts/test-whats-to-test.sh: curl is a
# stub on PATH that plays App Store Connect from fixture files and logs every
# call (method, URL, body), and the token minter is a fake. Nothing here
# reaches the network, and nothing here changes who receives a build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

mkdir -p "$TMP/bin" "$TMP/fx"
printf '#!/bin/bash\necho fake.jwt.token\n' > "$TMP/bin/jwt"; chmod +x "$TMP/bin/jwt"

# --- curl stub ----------------------------------------------------------------
# Routes by URL. Fixtures:
#   fx/builds.json          the build list for filter[version]=N (no group filter)
#   fx/in-group.json        the list for filter[version]=N&filter[betaGroups]=G,
#                           read BEFORE the POST (the "already there" probe)
#   fx/in-group-after.json  the same list read AFTER a POST (the read-back);
#                           when absent, in-group.json is served again
#   fx/groups.json          the group list for filter[name]
# FAILSTAGE names a URL substring whose call exits 22 (curl -f on a non-2xx).
# Every call is appended to curl.log as "<METHOD> <url>" and a POST body to
# post-body.json. Anything unrouted is a loud failure.
cat > "$TMP/bin/curl" <<STUB
#!/bin/bash
method=GET; url=""; body=""; prev=""
for a in "\$@"; do
    case "\$prev" in -X) method="\$a" ;; --data) body="\$a" ;; esac
    case "\$a" in https://*) url="\$a" ;; esac
    prev="\$a"
done
echo "\$method \$url" >> "$TMP/curl.log"
if [ -n "\${FAILSTAGE:-}" ]; then case "\$url" in *"\$FAILSTAGE"*) exit 22 ;; esac; fi
if [ "\$method" = POST ]; then
    case "\$url" in */v1/builds/*/relationships/betaGroups) printf '%s' "\$body" > "$TMP/post-body.json"; touch "$TMP/posted"; exit 0 ;; esac
    echo "stub curl: unhandled POST \$url" >&2; exit 64
fi
case "\$url" in
    *"/v1/apps?"*)                                   printf '%s' '{"data":[{"type":"apps","id":"APP1"}]}' ;;
    *"/v1/builds?"*"filter%5BbetaGroups%5D="*)       if [ -f "$TMP/posted" ] && [ -f "$TMP/fx/in-group-after.json" ]; then cat "$TMP/fx/in-group-after.json"; else cat "$TMP/fx/in-group.json"; fi ;;
    *"/v1/builds?"*)                                 cat "$TMP/fx/builds.json" ;;
    *"/v1/betaGroups?"*)                             cat "$TMP/fx/groups.json" ;;
    *) echo "stub curl: unhandled url \$url" >&2; exit 64 ;;
esac
STUB
chmod +x "$TMP/bin/curl"

valid_build()   { printf '%s' '{"data":[{"type":"builds","id":"BUILD231","attributes":{"version":"231","processingState":"VALID"}}]}' > "$TMP/fx/builds.json"; }
processing()    { printf '%s' '{"data":[{"type":"builds","id":"BUILD231","attributes":{"version":"231","processingState":"PROCESSING"}}]}' > "$TMP/fx/builds.json"; }
no_build()      { printf '%s' '{"data":[]}' > "$TMP/fx/builds.json"; }
group_exists()  { printf '%s' '{"data":[{"type":"betaGroups","id":"GRP-EXT","attributes":{"name":"External"}}]}' > "$TMP/fx/groups.json"; }
no_group()      { printf '%s' '{"data":[]}' > "$TMP/fx/groups.json"; }
not_in_group()  { printf '%s' '{"data":[]}' > "$TMP/fx/in-group.json"; }
in_group()      { printf '%s' '{"data":[{"type":"builds","id":"BUILD231"}]}' > "$TMP/fx/in-group.json"; }
readback_ok()   { printf '%s' '{"data":[{"type":"builds","id":"BUILD231"}]}' > "$TMP/fx/in-group-after.json"; }
readback_empty(){ printf '%s' '{"data":[]}' > "$TMP/fx/in-group-after.json"; }

reset_world() { rm -f "$TMP/curl.log" "$TMP/post-body.json" "$TMP/posted" "$TMP"/fx/*.json; valid_build; group_exists; not_in_group; readback_ok; }
run() { # args... ; env FAILSTAGE honoured
    env PATH="$TMP/bin:/usr/bin:/bin" ASC_JWT="$TMP/bin/jwt" FAILSTAGE="${FAILSTAGE:-}" "$ROOT/Scripts/promote-build.sh" "$@"
}
posted() { [ -f "$TMP/posted" ]; }

# 1. Success: a VALID build not yet in the group is assigned with the right
#    body (type betaGroups, the group's id), and the read-back confirms it.
reset_world
out="$(run 231 External 2>&1)" || fail "case 1: exit $?: $out"
posted || fail "case 1: no assignment POST was made"
grep -q '"type":"betaGroups"' "$TMP/post-body.json" && grep -q '"id":"GRP-EXT"' "$TMP/post-body.json" \
  || fail "case 1: POST body was $(cat "$TMP/post-body.json")"
grep -q 'POST .*/v1/builds/BUILD231/relationships/betaGroups' "$TMP/curl.log" || fail "case 1: POST went to the wrong build"
grep -q 'promoted build 231' <<<"$out" || fail "case 1: expected a promotion message, got: $out"
# The read-back happened AFTER the post.
awk '/POST/{p=NR} /betaGroups%5D=GRP-EXT/{if(p)r=NR} END{exit !(r>p)}' "$TMP/curl.log" || fail "case 1: no read-back after the POST"
pass "a valid build is assigned to the named group and read back"

# 2. Idempotent: already in the group -> exit 0, no POST. The rc tag may be
#    pushed twice; a promotion that is already true is not a failure.
reset_world; in_group
out="$(run 231 External 2>&1)" || fail "case 2: exit $?: $out"
posted && fail "case 2: an assignment POST was made for a build already in the group"
grep -q 'already in' <<<"$out" || fail "case 2: expected 'already in', got: $out"
pass "re-promoting a build already in the group succeeds without a POST"

# 3. Missing build -> exit 3, no POST, message names the number.
reset_world; no_build
if out="$(run 999 External 2>&1)"; then fail "case 3: a missing build exited 0"; fi
[ "$(run 999 External >/dev/null 2>&1; echo $?)" = 3 ] || fail "case 3: expected exit 3"
posted && fail "case 3: POST made for a missing build"
grep -q 'build 999 does not exist' <<<"$out" || fail "case 3: message was: $out"
pass "a build number that does not exist is refused with exit 3"

# 4. Still processing -> exit 4, no POST, message names the state.
reset_world; processing
[ "$(run 231 External >/dev/null 2>&1; echo $?)" = 4 ] || fail "case 4: expected exit 4"
out="$(run 231 External 2>&1 || true)"
posted && fail "case 4: POST made for a build that is still processing"
grep -q 'PROCESSING, not VALID' <<<"$out" || fail "case 4: message was: $out"
pass "a build whose processingState is not VALID is refused with exit 4"

# 5. Missing group -> exit 5, no POST, message names the group.
reset_world; no_group
[ "$(run 231 Nope >/dev/null 2>&1; echo $?)" = 5 ] || fail "case 5: expected exit 5"
out="$(run 231 Nope 2>&1 || true)"
posted && fail "case 5: POST made with no group"
grep -q "no TestFlight group named 'Nope'" <<<"$out" || fail "case 5: message was: $out"
pass "a group name that does not exist is refused with exit 5"

# 6. The POST says 2xx but the read-back does not list the build -> exit 6.
#    A 2xx is not proof the intended state landed.
reset_world; readback_empty
[ "$(run 231 External >/dev/null 2>&1; echo $?)" = 6 ] || fail "case 6: expected exit 6"
out="$(run 231 External 2>&1 || true)"
grep -q 'not listed in' <<<"$out" || fail "case 6: message was: $out"
pass "a successful POST with a failing read-back exits 6"

# 7. An API failure at any stage exits 1 and never POSTs. One stage at a
#    time, so a masked status anywhere is caught at its own call site.
for stage in "/v1/apps?" "filter%5Bversion%5D=231&limit" "/v1/betaGroups?"; do
    reset_world
    code="$(FAILSTAGE="$stage" run 231 External >/dev/null 2>&1; echo $?)"
    [ "$code" = 1 ] || fail "case 7: failure at '$stage' exited $code, not 1"
    posted && fail "case 7: POST made after a failure at '$stage'"
done
reset_world
code="$(FAILSTAGE="relationships/betaGroups" run 231 External >/dev/null 2>&1; echo $?)"
[ "$code" = 1 ] || fail "case 7: a failed POST exited $code, not 1"
pass "an App Store Connect failure at any stage exits 1 and assigns nothing"

# 8. Usage: missing or non-numeric arguments are refused before any call.
reset_world
[ "$(run 231 >/dev/null 2>&1; echo $?)" = 2 ] || fail "case 8: one argument should be a usage error"
[ "$(run abc External >/dev/null 2>&1; echo $?)" = 2 ] || fail "case 8: a non-numeric build should be a usage error"
[ -f "$TMP/curl.log" ] && fail "case 8: curl was called on a usage error"
pass "usage errors exit 2 before any call"

# 9. The group name is URL-encoded in the filter (spaces are the common case).
reset_world
run 231 "External Testers" >/dev/null 2>&1 || true
grep -q 'filter%5Bname%5D=External%20Testers' "$TMP/curl.log" || fail "case 9: group name was not encoded: $(grep betaGroups "$TMP/curl.log")"
pass "the group name is URL-encoded"

echo "All promote-build tests passed."
