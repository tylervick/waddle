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
#    rather than git's "Merge pull request" subject -- with the
#    conventional-commit prefix consumed for grouping rather than shown
#    (issue #93; cases 26-27 pin the grouping and stripping themselves).
r="$(make_repo derived 'merge_pr 78 "fix(ui): plural alert copy"; merge_pr 79 "chore: tidy"')"
out="$(notes "$r")" || fail "exited non-zero: $out"
echo "$out" | grep -q -- "- Plural alert copy" || fail "missing PR 78 bullet; got: $out"
echo "$out" | grep -q -- "- Tidy" || fail "missing PR 79 bullet; got: $out"
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
echo "$out" | grep -q -- "- Direct commit" || fail "direct commit missing; got: $out"
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

# 9. A merge commit whose body is empty (no PR title line) recovers a real
#    title rather than degrading to git's own "Merge pull request #N ..."
#    subject -- a branch name is not a change (issue #102; the original form
#    of this case pinned the degraded subject as intended behaviour). With no
#    origin remote there is nothing to fetch, so the recovery here is the
#    merged branch's tip commit subject -- merge_pr's fixture commit, "wip".
#    The $-anchor pins that no "(#N)" is appended to it either.
r="$(make_repo emptytitle 'merge_pr 99 ""')"
out="$(notes "$r")" || fail "an empty-body merge commit should not fail the run: $out"
echo "$out" | grep -q -- "- Wip$" \
  || fail "did not recover the merged branch's tip subject for an empty PR title; got: $out"
echo "$out" | grep -q "Merge pull request" \
  && fail "the raw merge subject leaked into the notes; got: $out"
pass "recovers the merged branch's tip subject when a merge commit's body is empty"

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
# FAILWRITE, if set, rejects only the WRITE -- the invocation carrying
# `-X POST` or `-X PATCH` -- the way App Store Connect rejects a malformed or
# conflicting localization, while every GET still succeeds. FAILSTAGE cannot
# express this: its URL substring for the write is `betaBuildLocalizations`,
# which matches the lookup GET first, so the write itself never sees the
# injected failure. Flag handling mirrors real curl exactly, and that is the
# point of the case:
#   --fail-with-body  non-zero exit AND Apple's error body on stdout
#   -f                non-zero exit, body thrown away
#   neither           EXIT 0 with the error body returned as the response --
#                     a rejected write read as success, which ships a green
#                     release with an empty What-to-Test field
if [ -n "${FAILWRITE:-}" ]; then
    case "$*" in *"-X POST"*|*"-X PATCH"*)
        err_body='{"errors":[{"status":"409","code":"ENTITY_ERROR.ATTRIBUTE.INVALID","detail":"WHATSNEW_REJECTED_BY_APPLE"}]}'
        for b in "$@"; do case "$b" in
            --fail-with-body) printf '%s\n' "$err_body"; exit 22 ;;
            -f) exit 22 ;;
        esac; done
        printf '%s\n' "$err_body"
        exit 0
    ;; esac
fi
for a in "$@"; do case "$a" in
    *"/v1/apps"*)                 cat "$STUBDIR/apps.json"; exit 0 ;;
    *"/v1/builds?"*)
        # Successive polls can be served DIFFERENT fixtures: builds.<n>.json
        # for the nth query when that file exists, builds.json otherwise.
        # Without this a case can only pin how one fixed answer is handled,
        # never that the script polls at all -- and "polls" is the property
        # that matters, since a real build is absent, then PROCESSING, then
        # VALID.
        n=$(( $(cat "$STUBDIR/builds.count" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$STUBDIR/builds.count"
        if [ -f "$STUBDIR/builds.$n.json" ]; then
            cat "$STUBDIR/builds.$n.json"
        else
            cat "$STUBDIR/builds.json"
        fi
        exit 0 ;;
    *"betaBuildLocalizations"*)
        case "$*" in *"--data-binary"*) cat > "$STUBDIR/body.json" ;; esac
        cat "$STUBDIR/loc.json"; exit 0 ;;
    *"api.github.com/repos/"*)
        # Pull-request body lookups: serve pr.<n>.json when the case provides
        # it, otherwise refuse the way real `curl -f` does on a 403/404 --
        # the fetch is best-effort and the script must fall back to subjects.
        n="${a##*/}"
        if [ -f "$STUBDIR/pr.$n.json" ]; then cat "$STUBDIR/pr.$n.json"; exit 0; fi
        exit 22 ;;
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

# Extracts data.id from a captured request body. A PATCH without it is
# rejected by App Store Connect, and nothing else in the body would show its
# absence -- the method alone cannot.
body_id() { # body.json path
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"].get("id",""))' "$1"
}

attach() { # dir, build-number
    (cd "$1" && env PATH="$1/bin:$PATH" STUBDIR="$1" ASC_JWT="$1/bin/asc-jwt.sh" \
        ASC_KEY_ID=K ASC_ISSUER_ID=I ASC_KEY_PATH=/dev/null \
        WHATS_TO_TEST_POLL_DELAY=0 \
        ./Scripts/whats-to-test.sh "$2" 2>&1)
}

# --print with the stubbed curl on PATH, for the pull-request-summary cases:
# unlike notes(), the fetch path needs STUBDIR so the curl stub can serve
# pr.<n>.json fixtures (or refuse, for the fallback case). Tokens cleared so
# a developer's or a CI step's GH_TOKEN never alters the invocation shape.
print_stubbed() { # dir
    (cd "$1" && env PATH="$1/bin:$PATH" STUBDIR="$1" GH_TOKEN= GITHUB_TOKEN= \
        ./Scripts/whats-to-test.sh --print 2>&1)
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
#     the PATCHed body also carries the exact assembled notes text AND the
#     localization's own id. App Store Connect rejects a PATCH whose
#     `data.id` is missing or disagrees with the URL, and no other assertion
#     here would notice its absence.
r="$(make_repo attach_patch 'merge_pr 91 "fix: a thing"')"; stub_curl "$r"
printf '%s' '{"data":[{"id":"loc-1","attributes":{"locale":"en-US"}}]}' > "$r/loc.json"
expected_notes="$(notes "$r")"
out="$(attach "$r" 207)" || fail "attach failed: $out"
grep -q "PATCH" "$r/curl.log" || fail "did not PATCH the existing localization"
grep -q "POST" "$r/curl.log" && fail "POSTed a duplicate localization"
got_notes="$(whats_new "$r/body.json")" || fail "PATCHed body is not valid JSON with a whatsNew field"
[ "$got_notes" = "$expected_notes" ] \
    || fail "PATCHed whatsNew does not match the assembled notes; expected: $expected_notes; got: $got_notes"
[ "$(body_id "$r/body.json")" = "loc-1" ] \
    || fail "PATCHed body does not carry data.id = loc-1; App Store Connect rejects that write"
pass "patches an existing en-US localization instead of duplicating it, carrying the assembled notes and its id"

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

# 13. A build the API NEVER knows about -- absent on every attempt, not just
#     the first -- fails rather than attaching to nothing, and says it never
#     appeared rather than blaming a parse. (Absent on the FIRST attempt is a
#     different thing entirely and must NOT fail: see case 22.)
r="$(make_repo attach_missing 'merge_pr 93 "fix: a thing"')"; stub_curl "$r"
printf '%s' '{"data":[]}' > "$r/builds.json"
if out="$(WHATS_TO_TEST_POLL_ATTEMPTS=2 attach "$r" 207)"; then fail "should fail when the build is not found"; fi
case "$out" in *207*) ;; *) fail "error does not name the build; got: $out" ;; esac
echo "$out" | grep -qi "never appeared" || fail "did not report the build as never appearing; got: $out"
grep -Eq "POST|PATCH" "$r/curl.log" && fail "attempted a write for a build that never appeared"
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

# 20. THE RELEASE-PATH CASE: the tag for the build being annotated already
#     exists, at HEAD, because the workflow pushes it in the step immediately
#     before this script runs. The changelog must anchor on the newest tag
#     BELOW that build (build-206), not on the newest tag overall (build-207,
#     which is HEAD and would make every range empty on every release).
#
#     This is the only fixture with two build tags, and it is what makes the
#     anchor selection provable: with a single tag, "newest tag" and "newest
#     tag below N" name the same commit, so every other case here passes
#     either way. Asserted on the captured request body rather than on
#     `--print`, because `--print` has no build number and deliberately keeps
#     anchoring on the newest tag.
r="$(make_repo attach_two_tags 'merge_pr 88 "fix(ui): the shipped change"; git tag build-207')"; stub_curl "$r"
out="$(attach "$r" 207)" || fail "attach failed with the current build already tagged: $out"
sent="$(whats_new "$r/body.json")" || fail "no valid request body was sent"
echo "$sent" | grep -q "Changes since build 206" \
    || fail "did not anchor on build-206, the newest tag below the build being annotated; sent: $sent"
echo "$sent" | grep -q "since build 207" \
    && fail "anchored on build-207 -- the tag for THIS build, at HEAD -- so the range is empty on every release; sent: $sent"
echo "$sent" | grep -q -- "- The shipped change" \
    || fail "the changelog bullets are missing; sent: $sent"
pass "anchors the changelog on the newest build tag BELOW the build being annotated"

# 21. `git tag --list` can write an advisory to stderr and still exit 0 (a
#     broken ref it skipped, for instance). Folding that into the captured
#     stdout makes the warning line the newest "tag" and therefore the
#     anchor: the range becomes `warning: ....HEAD`, `git log` fails inside
#     changelog's process substitution WITHOUT tripping `set -e`, and the
#     changelog silently vanishes.
r="$(make_repo tagwarns 'merge_pr 96 "fix: survives a git advisory"')"
mkdir -p "$r/stubbin"
REALGIT="$(command -v git)"
cat > "$r/stubbin/git" <<STUB
#!/bin/bash
if [ "\$1" = "tag" ] && [ "\$2" = "--list" ]; then
    echo "warning: ignoring broken ref refs/tags/build-bogus" >&2
fi
exec "$REALGIT" "\$@"
STUB
chmod +x "$r/stubbin/git"
out="$(cd "$r" && env PATH="$r/stubbin:$PATH" ./Scripts/whats-to-test.sh --print 2>/dev/null)" \
    || fail "a git advisory on stderr should not fail the run"
echo "$out" | grep -qi "since build 206" \
    || fail "a stderr advisory displaced the real tag as the changelog anchor; got: $out"
echo "$out" | grep -q -- "- Survives a git advisory" \
    || fail "the changelog vanished after a git advisory on stderr; got: $out"
pass "a git advisory on stderr does not become the changelog anchor"

# 22. A build App Store Connect has not indexed YET is polled for, not failed
#     on. `data: []` is the normal answer for the first minute or more after
#     altool returns -- the build resource appears when ingestion begins, not
#     when the upload completes -- so treating the first empty answer as
#     fatal fails a release that is merely early, at the one moment a retry
#     costs another build number.
r="$(make_repo attach_late 'merge_pr 106 "fix: a thing"')"; stub_curl "$r"
printf '%s' '{"data":[]}' > "$r/builds.1.json"
printf '%s' '{"data":[]}' > "$r/builds.2.json"
out="$(attach "$r" 207)" || fail "a build not yet indexed should be polled for, not failed on; got: $out"
grep -q "POST" "$r/curl.log" || fail "no localization was written after the build appeared"
queries="$(grep -c -- "/v1/builds?" "$r/curl.log" || true)"
[ "${queries:-0}" -ge 3 ] \
    || fail "polled the builds endpoint $queries time(s); an absent build was not retried"
pass "polls for a build App Store Connect has not indexed yet, instead of failing"

# 23. A build in PROCESSING is waited out. Every real build is PROCESSING on
#     the first response, so a script that breaks out of the poll
#     immediately would fail EVERY release -- and case 12 alone cannot see
#     that, since an unconditional break still produces its post-cap message.
r="$(make_repo attach_waits 'merge_pr 107 "fix: a thing"')"; stub_curl "$r"
printf '%s' '{"data":[{"id":"build-1","attributes":{"processingState":"PROCESSING"}}]}' > "$r/builds.1.json"
printf '%s' '{"data":[{"id":"build-1","attributes":{"processingState":"PROCESSING"}}]}' > "$r/builds.2.json"
out="$(attach "$r" 207)" || fail "should attach once the build leaves PROCESSING; got: $out"
grep -q "POST" "$r/curl.log" || fail "no localization was written after the build went VALID"
queries="$(grep -c -- "/v1/builds?" "$r/curl.log" || true)"
[ "${queries:-0}" -ge 3 ] \
    || fail "polled the builds endpoint $queries time(s); PROCESSING was not waited out"
pass "waits out PROCESSING and attaches once the build goes VALID"

# 24. A REJECTED WRITE fails the run, loudly, carrying Apple's own reason.
#     Only the POST/PATCH invocation is failed here -- FAILSTAGE's URL
#     substring matches the lookup GET first, so case 16 never exercises the
#     write at all. Deleting `--fail-with-body` from api_send makes real curl
#     exit 0 on a 4xx and hand back the error page as the response: the
#     script would print "Attached What-to-Test notes to build 207" and exit
#     0 while the field stayed empty. Downgrading it to bare `-f` still
#     fails, but throws away the only text that says WHY -- so both the exit
#     status and the presence of Apple's body are asserted.
r="$(make_repo attach_write_rejected 'merge_pr 108 "fix: a thing"')"; stub_curl "$r"
if out="$(FAILWRITE=1 attach "$r" 207)"; then
    fail "a rejected POST must not report success; got: $out"
fi
echo "$out" | grep -qi "failed to create the What-to-Test localization for build 207" \
    || fail "did not produce the create-failed diagnostic naming the build; got: $out"
echo "$out" | grep -q "WHATSNEW_REJECTED_BY_APPLE" \
    || fail "discarded Apple's error body, leaving only 'it failed'; got: $out"
echo "$out" | grep -qi "Attached What-to-Test notes" \
    && fail "claimed the notes were attached after the write was rejected; got: $out"

r="$(make_repo attach_patch_rejected 'merge_pr 109 "fix: a thing"')"; stub_curl "$r"
printf '%s' '{"data":[{"id":"loc-1","attributes":{"locale":"en-US"}}]}' > "$r/loc.json"
if out="$(FAILWRITE=1 attach "$r" 207)"; then
    fail "a rejected PATCH must not report success; got: $out"
fi
echo "$out" | grep -qi "failed to update the What-to-Test localization for build 207" \
    || fail "did not produce the update-failed diagnostic naming the build; got: $out"
echo "$out" | grep -q "WHATSNEW_REJECTED_BY_APPLE" \
    || fail "discarded Apple's error body on the PATCH path; got: $out"
pass "fails loudly with Apple's reason when the localization write is rejected"

# 25. App Store Connect caps whatsNew at about 4000 characters and rejects an
#     over-long value AFTER the upload and the tag -- so the notes are
#     trimmed to whole bullets below the cap, with a count of what was
#     dropped. Enough real commits are generated to overrun the cap, so this
#     pins the SHIPPED constant, not a test-only override.
LONGPAD="$(python3 -c 'print("x" * 100)')"
r="$(make_repo longnotes "for i in \$(seq 1 40); do git commit -q --allow-empty -m \"fix(engine): change \$i $LONGPAD\"; done")"
out="$(notes "$r")" || fail "long notes should not fail the run; got the first line: $(echo "$out" | head -1)"
chars="$(printf '%s' "$out" | python3 -c 'import sys; print(len(sys.stdin.read()))')"
[ "$chars" -le 4000 ] \
    || fail "assembled notes are $chars characters; App Store Connect rejects that AFTER the upload"
echo "$out" | grep -qE "… and [0-9]+ more changes" \
    || fail "trimmed the notes without saying how many changes were dropped; got the tail: $(echo "$out" | tail -2)"
echo "$out" | grep -qi "since build 206" || fail "trimming dropped the heading; got: $(echo "$out" | head -2)"
echo "$out" | grep -q -- "- Change 40" \
    || fail "trimming dropped the newest bullets instead of the oldest; got: $(echo "$out" | head -3)"
pass "trims over-long notes to whole bullets under the cap and says how many were dropped"

# 26. THE GROUPING CASE (issue #93): a mix of app and non-app commits all
#     still appear, each under the right heading, newest first within its
#     group. feat(loop) is the discriminating entry: its TYPE says
#     app-facing but its SCOPE is tooling, so type-only grouping fails this
#     case -- and so does dropping any commit on the floor, since everything
#     stays in the notes by the owner's ruling.
r="$(make_repo grouped 'merge_pr 110 "docs(learnings): write down a trap"; merge_pr 111 "fix(ui): straighten the alert copy"; merge_pr 112 "feat(loop): tune the loop protocol"; merge_pr 113 "feat(library): add a sort toggle"')"
out="$(notes "$r")" || fail "grouped case exited non-zero: $out"
for want in "- Write down a trap" "- Straighten the alert copy" "- Tune the loop protocol" "- Add a sort toggle"; do
    echo "$out" | grep -qF -- "$want" || fail "missing bullet '$want'; got: $out"
done
app_h="$(echo "$out" | grep -n "^In the app:" | cut -d: -f1)"
oth_h="$(echo "$out" | grep -n "^Behind the scenes:" | cut -d: -f1)"
[ -n "$app_h" ] || fail "no 'In the app:' heading; got: $out"
[ -n "$oth_h" ] || fail "no 'Behind the scenes:' heading; got: $out"
l_sort="$(echo "$out" | grep -nF -- "- Add a sort toggle" | cut -d: -f1)"
l_alert="$(echo "$out" | grep -nF -- "- Straighten the alert copy" | cut -d: -f1)"
l_loop="$(echo "$out" | grep -nF -- "- Tune the loop protocol" | cut -d: -f1)"
l_trap="$(echo "$out" | grep -nF -- "- Write down a trap" | cut -d: -f1)"
[ "$app_h" -lt "$l_sort" ] && [ "$l_sort" -lt "$l_alert" ] && [ "$l_alert" -lt "$oth_h" ] \
    || fail "app bullets are not under 'In the app:' newest-first; got: $out"
[ "$oth_h" -lt "$l_loop" ] && [ "$l_loop" -lt "$l_trap" ] \
    || fail "tooling bullets are not under 'Behind the scenes:' newest-first; got: $out"
pass "groups a mixed range under the right headings, keeping every commit, newest first"

# 27. The conventional-commit prefix and the PR number are consumed, never
#     shown: they are the grouping signal and a link a tester cannot follow,
#     not tester vocabulary (issue #93).
r="$(make_repo stripped 'merge_pr 114 "fix(ui): polish the import alert"')"
out="$(notes "$r")" || fail "stripped case exited non-zero: $out"
echo "$out" | grep -qF -- "- Polish the import alert" || fail "stripped subject missing; got: $out"
echo "$out" | grep -qF "fix(ui)" && fail "conventional-commit prefix leaked into the visible text; got: $out"
echo "$out" | grep -qE '\(#[0-9]+\)' && fail "a PR number leaked into the visible text; got: $out"
pass "strips the conventional-commit prefix and PR number from the visible text"

# 28. A pull request body is available: the bullet uses its first prose
#     sentence -- the body is where a change is explained in plain language
#     -- instead of the commit subject. Headings are skipped and emphasis
#     unwrapped. Hermetic: the origin remote plus the stubbed curl serve the
#     body from pr.120.json; nothing touches the network.
r="$(make_repo prbody 'merge_pr 120 "fix(ui): terse reviewer-facing subject"')"
stub_curl "$r"
(cd "$r" && git remote add origin https://github.com/tylervick/waddle.git)
printf '%s' '{"body":"## What\n\nThe **File in use** alert now names every blocked file, so a tester can see which import is stuck.\n\nMore reviewer detail follows."}' > "$r/pr.120.json"
out="$(print_stubbed "$r")" || fail "prbody case exited non-zero: $out"
echo "$out" | grep -qF -- "- The File in use alert now names every blocked file, so a tester can see which import is stuck." \
    || fail "did not use the PR body's first sentence; got: $out"
echo "$out" | grep -qF "terse reviewer-facing subject" && fail "kept the commit subject despite a usable PR body; got: $out"
pass "uses the first prose sentence of the PR body when one is available"

# 29. The body is UNAVAILABLE -- the API refuses, as under a rate limit, a
#     deleted PR, or a token without pull-requests: read -- and the run
#     still succeeds, with the stripped commit subject as the bullet. This
#     is the fail-soft the release path requires: prose is decoration, and a
#     rate limit must never fail a release after the upload and the tag. No
#     pr.<n>.json exists, so the stub refuses exactly like real `curl -f`
#     on a 403.
r="$(make_repo prfallback 'merge_pr 121 "fix(ui): survive an api outage"')"
stub_curl "$r"
(cd "$r" && git remote add origin git@github.com:tylervick/waddle.git)
out="$(print_stubbed "$r")" || fail "an unavailable PR body must not fail the run; got: $out"
echo "$out" | grep -qF -- "- Survive an api outage" || fail "did not fall back to the commit subject; got: $out"
pass "falls back to the commit subject, still succeeding, when the PR body is unavailable"

# 30. Nothing app-facing in the range: the notes say so outright instead of
#     leaving a bare tooling section to imply it -- "nothing to retest" is
#     the most useful fact those notes can carry.
r="$(make_repo onlytooling 'merge_pr 122 "chore: tidy the scripts"')"
out="$(notes "$r")" || fail "onlytooling case exited non-zero: $out"
echo "$out" | grep -qF "Nothing in the app itself changed in this build." || fail "missing the nothing-changed line; got: $out"
echo "$out" | grep -q "^In the app:" && fail "an empty 'In the app:' section was emitted; got: $out"
echo "$out" | grep -qF -- "- Tidy the scripts" || fail "the tooling bullet vanished; got: $out"
pass "states outright when nothing in the app itself changed"

# 31. An empty-body merge commit WITH the pull request reachable (issue
#     #102): the title is recovered from the PR -- the same response the
#     prose summary rides on -- so the bullet is the body's first sentence,
#     grouped by the RECOVERED title's prefix. That title is tooling-scoped
#     (feat(loop) -> behind the scenes) ON PURPOSE: the old code grouped an
#     empty-body merge by its unparseable merge subject, which defaults to
#     "In the app:", and the tip-subject fallback here is "wip", which also
#     defaults there -- so this case fails both if recovery never runs and
#     if it settles for the tip subject without trying the API. Grouping is
#     the discriminator; the body sentence alone cannot be, because the old
#     code already decorated reachable PRs with it.
r="$(make_repo emptyrecovered 'merge_pr 130 ""')"
stub_curl "$r"
(cd "$r" && git remote add origin https://github.com/tylervick/waddle.git)
printf '%s' '{"title":"feat(loop): retune the trial cadence","body":"The loop now waits out CI before fixing anything."}' > "$r/pr.130.json"
out="$(print_stubbed "$r")" || fail "emptyrecovered case exited non-zero: $out"
echo "$out" | grep -qF -- "- The loop now waits out CI before fixing anything." \
    || fail "did not use the PR body sentence after recovering the title; got: $out"
echo "$out" | grep -q "^Behind the scenes:" \
    || fail "grouped by the merge subject or the tip fallback, not the recovered PR title; got: $out"
echo "$out" | grep -qF "Nothing in the app itself changed in this build." \
    || fail "the recovered feat(loop) change leaked into 'In the app:'; got: $out"
echo "$out" | grep -q "Merge pull request" \
    && fail "the raw merge subject leaked despite a reachable PR; got: $out"
pass "recovers an empty-body merge's title from the reachable PR and groups by it"

# 32. An empty-body merge commit with the fetch UNAVAILABLE (issue #102): the
#     chosen fallback -- the merged branch's tip commit subject -- appears,
#     stripped and grouped by its own prefix, the run still exits 0, and
#     nothing reads as a branch name. No pr.132.json exists, so the stub
#     refuses exactly like real `curl -f` under a rate limit.
r="$(make_repo emptyoffline 'git checkout -q -b topic-132; git commit -q --allow-empty -m "fix(ui): steady the import alert"; git checkout -q -; git merge -q --no-ff topic-132 -m "Merge pull request #132 from tylervick/topic-132"')"
stub_curl "$r"
(cd "$r" && git remote add origin https://github.com/tylervick/waddle.git)
out="$(print_stubbed "$r")" || fail "an unreachable PR must not fail an empty-body merge; got: $out"
echo "$out" | grep -qF -- "- Steady the import alert" \
    || fail "did not fall back to the merged branch's tip subject; got: $out"
echo "$out" | grep -q "Merge pull request" \
    && fail "the raw merge subject leaked when the fetch was unavailable; got: $out"
echo "$out" | grep -q "topic-132" \
    && fail "a branch name leaked into the notes; got: $out"
pass "falls back to the tip commit subject, still exiting 0, when the fetch is unavailable"

# 33. THE MEASURED MISGROUPING (issue #102): a docs-prefixed empty-body merge
#     -- #100's exact shape -- lands under "Behind the scenes:", not in "In
#     the app:" where the unparseable merge subject used to default it. The
#     PR is reachable with a docs title and no usable body, so the visible
#     text is the recovered, stripped title itself.
r="$(make_repo emptydocs 'merge_pr 133 ""; merge_pr 134 "fix(ui): keep one app-facing change"')"
stub_curl "$r"
(cd "$r" && git remote add origin https://github.com/tylervick/waddle.git)
printf '%s' '{"title":"docs(spec): record the loop keyword exclusions","body":""}' > "$r/pr.133.json"
printf '%s' '{"body":""}' > "$r/pr.134.json"
out="$(print_stubbed "$r")" || fail "emptydocs case exited non-zero: $out"
echo "$out" | grep -qF -- "- Record the loop keyword exclusions" \
    || fail "missing the recovered docs bullet; got: $out"
oth_h="$(echo "$out" | grep -n "^Behind the scenes:" | cut -d: -f1)"
l_docs="$(echo "$out" | grep -nF -- "- Record the loop keyword exclusions" | cut -d: -f1)"
[ -n "$oth_h" ] || fail "no 'Behind the scenes:' heading; got: $out"
[ "$oth_h" -lt "$l_docs" ] \
    || fail "the docs-prefixed empty-body merge was not grouped behind the scenes; got: $out"
pass "groups a docs-prefixed empty-body merge behind the scenes via its recovered title"

echo "All whats-to-test tests passed."
