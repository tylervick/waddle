#!/bin/bash
# Tests for Scripts/whats-to-test.sh.
#
# HERMETIC: every case builds a throwaway git repository under $TMP and runs
# the script inside it. Nothing here reads the real checkout or the network.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# Builds a repo with a build-206 tag, then applies $2 to add history on top.
# $3, if given, seeds docs/app-store/whats-to-test.md BEFORE the base commit
# and the tag -- so a fixture that wants "a preamble exists but nothing has
# been committed since the tag" gets that precondition for real, rather than
# writing the preamble via a commit that lands after build-206 and therefore
# inside its own "since the tag" range.
# Signing and the user's global config are isolated -- see
# docs/learnings/git-fixtures-inherit-signing-config.md.
make_repo() { # name, mutate-script, [preamble-content]
    d="$TMP/$1"; mkdir -p "$d/docs/app-store" "$d/Scripts"; cd "$d"
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    git init -q .; git config user.email t@e.st; git config user.name T
    git config commit.gpgsign false; git config tag.gpgSign false
    cp "$ROOT/Scripts/whats-to-test.sh" Scripts/whats-to-test.sh
    chmod +x Scripts/whats-to-test.sh
    printf '%s' "${3:-}" > docs/app-store/whats-to-test.md
    git add -A; git commit -qm base
    git tag build-206
    eval "$2"
    cd - >/dev/null
    echo "$d"
}

# A merge commit shaped exactly as GitHub writes them: the subject names the
# PR, the body's first line is the PR title.
merge_pr() { # number, title
    git checkout -q -b "pr-$1"
    git commit -q --allow-empty -m "wip"
    git checkout -q -
    git merge -q --no-ff "pr-$1" -m "Merge pull request #$1 from tylervick/pr-$1

$2"
}

notes() { (cd "$1" && ./Scripts/whats-to-test.sh --print 2>&1); }

# 1. Merged PRs since the tag become one bullet each, titled by the PR title
#    rather than git's "Merge pull request" subject.
r="$(make_repo derived 'merge_pr 78 "fix(ui): plural alert copy"; merge_pr 79 "chore: tidy"')"
out="$(notes "$r")" || fail "exited non-zero: $out"
echo "$out" | grep -q -- "- fix(ui): plural alert copy (#78)" || fail "missing PR 78 bullet; got: $out"
echo "$out" | grep -q -- "- chore: tidy (#79)" || fail "missing PR 79 bullet; got: $out"
echo "$out" | grep -qi "since build 206" || fail "does not name the previous build; got: $out"
pass "derives one bullet per merged PR since the last build tag"

# 2. A preamble is included verbatim, above the changelog.
r="$(make_repo preamble 'printf "Focus on the Library screen.\n" > docs/app-store/whats-to-test.md; git add -A; git commit -qm p; merge_pr 80 "fix: thing"')"
out="$(notes "$r")"
echo "$out" | grep -q "Focus on the Library screen." || fail "preamble missing; got: $out"
[ "$(echo "$out" | grep -n "Focus on the Library" | cut -d: -f1)" -lt \
  "$(echo "$out" | grep -n "since build 206" | cut -d: -f1)" ] \
  || fail "preamble is not above the changelog"
pass "includes a preamble verbatim, above the changelog"

# 3. An empty preamble is normal, not an error -- the derived half carries it.
r="$(make_repo emptypre 'merge_pr 81 "fix: thing"')"
notes "$r" >/dev/null || fail "an empty preamble should not fail the run"
pass "an empty preamble is not an error"

# 4. No commits since the tag AND no preamble -> fails. Nothing to say.
r="$(make_repo nothing '')"
if notes "$r" >"$TMP/o4" 2>&1; then fail "should have failed with nothing to report"; fi
grep -qi "no changes" "$TMP/o4" || fail "error did not explain; got: $(cat "$TMP/o4")"
pass "fails when there are no changes and no preamble"

# 5. No commits since the tag but a preamble exists -> succeeds on the
#    preamble alone. A re-release with hand-written framing is legitimate.
#    The preamble is seeded into the BASE commit (via make_repo's $3), before
#    build-206 is tagged, so build-206..HEAD is genuinely empty here. Writing
#    the preamble as a commit AFTER the tag would put that very commit inside
#    the range, so the case would pass even if a changelog section leaked
#    into the output alongside the preamble -- it must also assert the
#    changelog's absence, not just the preamble's presence, or it cannot tell
#    "preamble carried it alone" from "preamble plus a stray bullet".
r="$(make_repo onlypre '' $'Re-testing build 206 signing.\n')"
out="$(notes "$r")" || fail "should succeed on a preamble alone"
echo "$out" | grep -q "Re-testing build 206 signing." || fail "preamble missing; got: $out"
echo "$out" | grep -q "Changes since" && fail "a changelog section leaked in when nothing was committed since the tag; got: $out"
pass "succeeds on a preamble alone when nothing merged"

# 6. No build-* tag at all (the bootstrap case, true exactly once) -> falls
#    back to recent history and SAYS SO, rather than failing a release.
r="$(make_repo notag 'git tag -d build-206 >/dev/null; merge_pr 82 "fix: thing"')"
out="$(notes "$r")" || fail "bootstrap case should not fail; got: $out"
echo "$out" | grep -qi "no previous build tag" || fail "did not disclose the fallback; got: $out"
pass "falls back to recent history when no build tag exists, and says so"

# 7. Direct commits to the branch (no merge commit) still appear.
r="$(make_repo direct 'git commit -q --allow-empty -m "fix(engine): direct commit"')"
out="$(notes "$r")"
echo "$out" | grep -q -- "- fix(engine): direct commit" || fail "direct commit missing; got: $out"
pass "includes direct commits, not only merges"

# 8. A genuine `git tag --list` failure (corrupt refs, a shallow or partial
#    checkout) must NOT be silently folded into the "no tag yet" bootstrap
#    path -- both produce empty stdout, so only testing the exit status
#    separates them. `git` itself is stubbed on a controlled PATH so it fails
#    only for the `tag --list` call the script makes; every other git
#    invocation (log, checkout, merge, ...) still reaches the real binary, so
#    this is hermetic without corrupting an actual repository.
r="$(make_repo tagfails 'merge_pr 95 "fix: thing"')"
mkdir -p "$r/stubbin"
REALGIT="$(command -v git)"
cat > "$r/stubbin/git" <<STUB
#!/bin/bash
if [ "\$1" = "tag" ] && [ "\$2" = "--list" ]; then
    echo "fatal: stubbed git tag failure" >&2
    exit 128
fi
exec "$REALGIT" "\$@"
STUB
chmod +x "$r/stubbin/git"
if out="$(cd "$r" && env PATH="$r/stubbin:$PATH" ./Scripts/whats-to-test.sh --print 2>&1)"; then
    fail "a git tag failure should not be silently treated as a successful run; got: $out"
fi
echo "$out" | grep -qi "git tag" || fail "error did not name git tag as the point of failure; got: $out"
echo "$out" | grep -qi "no previous build tag" && fail "a real git failure must not read as the bootstrap fallback; got: $out"
pass "fails loudly, not via the bootstrap fallback, when git tag --list itself fails"

# 9. A merge commit whose body is empty (no PR title line) falls back to the
#    raw "Merge pull request #N ..." subject rather than crashing or emitting
#    a blank bullet.
r="$(make_repo emptytitle 'merge_pr 99 ""')"
out="$(notes "$r")" || fail "an empty-body merge commit should not fail the run: $out"
echo "$out" | grep -q -- "- Merge pull request #99 from tylervick/pr-99 (#99)" \
  || fail "did not fall back to the raw merge subject for an empty PR title; got: $out"
pass "falls back to the raw merge subject when a merge commit's body is empty"

# A curl stub driven by files, so each case chooses its own responses. It
# records every invocation so the tests can assert what was sent, and
# captures any --data-binary request body to body.json so a case can assert
# on the JSON that was actually going to reach App Store Connect, not just
# infer it from the HTTP method used.
stub_curl() { # dir
    mkdir -p "$1/bin"
    cat > "$1/bin/curl" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUBDIR/curl.log"
# FAILSTAGE/MALFORMED, if set, name a URL substring at which this stub
# simulates a real API problem at that one call site while every other call
# still succeeds normally:
#   FAILSTAGE  a hard failure -- but only if the invocation actually carries
#              -f or --fail-with-body, exactly as real curl requires: with
#              neither flag present, curl exits 0 on a non-2xx and simply
#              writes the error page as the body instead of failing. So this
#              stub does the same, falling through to the "not valid JSON"
#              response below -- which makes an accidental `-f` deletion
#              from the real script produce exactly what it would in
#              production (a false "success" with a garbage body), not a
#              behavior the mock stub can't express.
#   MALFORMED  a malformed-but-200 response regardless of flags: exit 0, but
#              a body that is not valid JSON (a proxy interstitial, a
#              truncated gateway response). Deliberately distinct from a
#              genuine `{"data":[]}`, which needs neither of these -- it's
#              simulated by simply writing an empty-data fixture file.
if [ -n "${FAILSTAGE:-}" ]; then
    for a in "$@"; do case "$a" in *"$FAILSTAGE"*)
        has_fail_flag=0
        for b in "$@"; do case "$b" in -f|--fail-with-body) has_fail_flag=1 ;; esac; done
        if [ "$has_fail_flag" -eq 1 ]; then
            exit 22
        else
            echo 'not-json-at-all'
            exit 0
        fi
    ;; esac; done
fi
if [ -n "${MALFORMED:-}" ]; then
    for a in "$@"; do case "$a" in *"$MALFORMED"*) echo 'not-json-at-all'; exit 0 ;; esac; done
fi
for a in "$@"; do case "$a" in
    *"/v1/apps"*)                 cat "$STUBDIR/apps.json"; exit 0 ;;
    *"/v1/builds?"*)              cat "$STUBDIR/builds.json"; exit 0 ;;
    *"betaBuildLocalizations"*)
        case "$*" in *"--data-binary"*) cat > "$STUBDIR/body.json" ;; esac
        cat "$STUBDIR/loc.json"; exit 0 ;;
esac; done
echo '{}'
STUB
    chmod +x "$1/bin/curl"
    printf '%s' '{"data":[{"id":"app-1"}]}' > "$1/apps.json"
    printf '%s' '{"data":[{"id":"build-1","attributes":{"processingState":"VALID"}}]}' > "$1/builds.json"
    printf '%s' '{"data":[]}' > "$1/loc.json"
    # asc-jwt.sh is stubbed too: minting a real token needs a real key, and
    # Scripts/test-asc-jwt.sh already covers the token itself.
    cat > "$1/bin/asc-jwt.sh" <<'STUB'
#!/bin/bash
echo "stub.jwt.token"
STUB
    chmod +x "$1/bin/asc-jwt.sh"
}

# Extracts attributes.whatsNew from a captured request body, so a case can
# assert the exact assembled notes text reached App Store Connect rather
# than merely that some POST or PATCH happened.
whats_new() { # body.json path
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["attributes"]["whatsNew"])' "$1"
}

attach() { # dir, build-number
    (cd "$1" && env PATH="$1/bin:$PATH" STUBDIR="$1" ASC_JWT="$1/bin/asc-jwt.sh" \
        ASC_KEY_ID=K ASC_ISSUER_ID=I ASC_KEY_PATH=/dev/null \
        WHATS_TO_TEST_POLL_DELAY=0 \
        ./Scripts/whats-to-test.sh "$2" 2>&1)
}

# 10. No existing localization -> POST, and the exact assembled notes text
#     is what's sent -- captured from the real --data-binary stdin body via
#     the stub, then round-tripped back out through json.load, not merely
#     inferred from the HTTP method (the body can never appear in the stub's
#     `$*` arg log, since it travels over stdin).
r="$(make_repo attach_post 'merge_pr 90 "fix: a thing"')"; stub_curl "$r"
expected_notes="$(notes "$r")"
out="$(attach "$r" 207)" || fail "attach failed: $out"
grep -q "POST" "$r/curl.log" || fail "did not POST a new localization; log: $(cat "$r/curl.log")"
got_notes="$(whats_new "$r/body.json")" || fail "POSTed body is not valid JSON with a whatsNew field"
[ "$got_notes" = "$expected_notes" ] \
    || fail "POSTed whatsNew does not match the assembled notes; expected: $expected_notes; got: $got_notes"
pass "creates a localization when none exists, carrying the assembled notes"

# 11. An existing en-US localization -> PATCH, never a duplicate POST, and
#     the PATCHed body also carries the exact assembled notes text.
r="$(make_repo attach_patch 'merge_pr 91 "fix: a thing"')"; stub_curl "$r"
printf '%s' '{"data":[{"id":"loc-1","attributes":{"locale":"en-US"}}]}' > "$r/loc.json"
expected_notes="$(notes "$r")"
out="$(attach "$r" 207)" || fail "attach failed: $out"
grep -q "PATCH" "$r/curl.log" || fail "did not PATCH the existing localization"
grep -q "POST" "$r/curl.log" && fail "POSTed a duplicate localization"
got_notes="$(whats_new "$r/body.json")" || fail "PATCHed body is not valid JSON with a whatsNew field"
[ "$got_notes" = "$expected_notes" ] \
    || fail "PATCHed whatsNew does not match the assembled notes; expected: $expected_notes; got: $got_notes"
pass "patches an existing en-US localization instead of duplicating it, carrying the assembled notes"

# 12. A build stuck in PROCESSING past the cap fails, and the message names
#     the build number so the operator knows which build is affected.
# (WHATS_TO_TEST_POLL_ATTEMPTS is set as a plain assignment prefix on `attach`
# itself, not via `env attach ...` -- `attach` is a shell function, and `env`
# execs a binary by that name from PATH, which does not exist. A prefix
# assignment on a function call sets the variable for that call only, without
# leaking it back into this script, which is exactly what's needed here.)
r="$(make_repo attach_processing 'merge_pr 92 "fix: a thing"')"; stub_curl "$r"
printf '%s' '{"data":[{"id":"build-1","attributes":{"processingState":"PROCESSING"}}]}' > "$r/builds.json"
if out="$(WHATS_TO_TEST_POLL_ATTEMPTS=2 attach "$r" 207)"; then
    fail "a build stuck in PROCESSING should fail"
fi
case "$out" in *207*) ;; *) fail "error does not name the build number; got: $out" ;; esac
pass "fails when the build never leaves PROCESSING, naming the build"

# 13. A build the API does not know about fails rather than attaching to
#     nothing.
r="$(make_repo attach_missing 'merge_pr 93 "fix: a thing"')"; stub_curl "$r"
printf '%s' '{"data":[]}' > "$r/builds.json"
if attach "$r" 207 >"$TMP/o11" 2>&1; then fail "should fail when the build is not found"; fi
grep -q "207" "$TMP/o11" || fail "error does not name the build; got: $(cat "$TMP/o11")"
pass "fails when App Store Connect does not have the build"

# 14. A failed call to resolve the app id aborts loudly, names the build,
#     attempts no write, and does not leak a raw python traceback -- curl's
#     own failure is tested before ever piping into json_first. Asserts the
#     exact clean-message wording, not just "some failure happened": a
#     downstream parse-failure catch (added for case 17/18) would also make
#     this fail closed, so without pinning the wording, deleting THIS guard
#     specifically wouldn't be provable -- see the task report's break/
#     restore proof for why the wording assertion is what makes it provable.
r="$(make_repo attach_appid_fails 'merge_pr 100 "fix: a thing"')"; stub_curl "$r"
if out="$(FAILSTAGE=/v1/apps attach "$r" 207)"; then fail "should fail when the app id lookup fails"; fi
case "$out" in *207*) ;; *) fail "error does not name the build number; got: $out" ;; esac
case "$out" in *Traceback*) fail "leaked a raw python traceback instead of a clean diagnostic; got: $out" ;; esac
echo "$out" | grep -qi "could not resolve the app id" || fail "did not produce the app-id-lookup diagnostic; got: $out"
grep -Eq "POST|PATCH" "$r/curl.log" && fail "attempted a write after the app id lookup failed"
pass "fails without a write when the app id lookup fails, naming the build"

# 15. A failed call while polling builds aborts loudly rather than being
#     read as "no build found" or falling through to a write. Wording
#     pinned for the same reason as case 14.
r="$(make_repo attach_builds_fail 'merge_pr 101 "fix: a thing"')"; stub_curl "$r"
if out="$(FAILSTAGE="/v1/builds?" attach "$r" 207)"; then fail "should fail when the builds poll fails"; fi
case "$out" in *207*) ;; *) fail "error does not name the build number; got: $out" ;; esac
echo "$out" | grep -qi "could not query App Store Connect" || fail "did not produce the builds-poll diagnostic; got: $out"
grep -Eq "POST|PATCH" "$r/curl.log" && fail "attempted a write after the builds poll failed"
pass "fails without a write when the builds poll fails, naming the build"

# 16. A failed localization lookup aborts loudly rather than being read as
#     "no existing localization" and posting a duplicate -- the exact defect
#     this branch exists to rule out. Wording pinned for the same reason as
#     case 14.
r="$(make_repo attach_loc_fails 'merge_pr 102 "fix: a thing"')"; stub_curl "$r"
if out="$(FAILSTAGE=betaBuildLocalizations attach "$r" 207)"; then fail "should fail when the localization lookup fails"; fi
case "$out" in *207*) ;; *) fail "error does not name the build number; got: $out" ;; esac
echo "$out" | grep -qi "could not look up beta build localizations" || fail "did not produce the localization-lookup diagnostic; got: $out"
grep -Eq "POST|PATCH" "$r/curl.log" && fail "attempted a write after the localization lookup failed"
pass "fails without a write when the localization lookup fails, naming the build"

# 17. A malformed-but-200 builds response aborts loudly and distinctly from
#     "build not found" -- an unparseable body must not be misdiagnosed as an
#     absent build.
r="$(make_repo attach_builds_malformed 'merge_pr 103 "fix: a thing"')"; stub_curl "$r"
if out="$(MALFORMED="/v1/builds?" attach "$r" 207)"; then fail "should fail on a malformed builds response"; fi
case "$out" in *207*) ;; *) fail "error does not name the build number; got: $out" ;; esac
case "$out" in *Traceback*) fail "leaked a raw python traceback instead of a clean diagnostic; got: $out" ;; esac
echo "$out" | grep -qi "has no build" && fail "a malformed body was misdiagnosed as an absent build; got: $out"
pass "fails distinctly on a malformed builds response, not as a false 'build not found'"

# 18. A malformed-but-200 localization response aborts loudly rather than
#     being read as "no existing localization" and posting a duplicate.
r="$(make_repo attach_loc_malformed 'merge_pr 104 "fix: a thing"')"; stub_curl "$r"
if out="$(MALFORMED=betaBuildLocalizations attach "$r" 207)"; then fail "should fail on a malformed localization response"; fi
case "$out" in *207*) ;; *) fail "error does not name the build number; got: $out" ;; esac
case "$out" in *Traceback*) fail "leaked a raw python traceback instead of a clean diagnostic; got: $out" ;; esac
grep -Eq "POST|PATCH" "$r/curl.log" && fail "attempted a write after a malformed localization lookup"
pass "fails on a malformed localization response rather than posting a duplicate"

# 19. POLL_ATTEMPTS <= 0 fails cleanly, naming the build, rather than
#     crashing on a STATE or BUILD_ID that was never initialized (`set -u`
#     would otherwise kill the script with a bare "unbound variable").
r="$(make_repo attach_zero_attempts 'merge_pr 105 "fix: a thing"')"; stub_curl "$r"
if out="$(WHATS_TO_TEST_POLL_ATTEMPTS=0 attach "$r" 207)"; then fail "should fail when POLL_ATTEMPTS is 0"; fi
case "$out" in *207*) ;; *) fail "error does not name the build number; got: $out" ;; esac
echo "$out" | grep -qi "unbound variable" && fail "crashed on an unbound variable instead of failing cleanly; got: $out"
pass "fails cleanly, naming the build, when POLL_ATTEMPTS is zero"

echo "All whats-to-test tests passed."
