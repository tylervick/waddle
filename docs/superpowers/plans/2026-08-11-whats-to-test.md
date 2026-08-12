# TestFlight "What to Test" Notes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attach "What to Test" notes to every TestFlight build automatically, derived from the commits since the last build so they cannot go stale.

**Architecture:** Two shell guards in the repo's existing idiom — `Scripts/asc-jwt.sh` mints an ES256 JWT for the App Store Connect REST API, and `Scripts/whats-to-test.sh` assembles the notes and attaches them to a build. `.github/workflows/testflight.yml` tags each successful upload and then calls the attach script.

**Tech Stack:** bash 3.2, `openssl`, pure-stdlib `python3`, `curl`, GitHub Actions, App Store Connect REST API v1.

**Spec:** `docs/superpowers/specs/2026-08-11-whats-to-test-design.md` (commit `ac3549c`). Read it before Task 1.

## Global Constraints

- `set -euo pipefail` in every script; macOS **bash 3.2** — no associative arrays, no `mapfile`, no `${var^^}`.
- **Never mask an exit status you then interpret as data.** Read `docs/learnings/masked-exit-status-fails-open.md`. Test status directly: `if out="$(cmd)"; then`. `|| true` only where a non-zero status IS the expected answer (`grep` with no matches).
- A `while` fed by a pipe runs in a subshell and loses assignments (`docs/learnings/command-substitution-discards-callee-state.md`); `$(...)` around a function call discards its global writes and swallows its `exit`; a loop body's trailing `&&`-list flips the loop's status only when the loop is a pipeline stage (`docs/learnings/loop-body-last-status-triggers-errexit.md`).
- **No new runtime dependencies.** No `pip install`, no PyJWT, no `jq`-only logic that isn't already available. `python3` stdlib, `openssl`, `curl` and `git` only.
- **This is the release path. It is owner-only and must never be `agent:eligible`.** Do not add it to the loop's backlog.
- Secrets must never reach a log. A decoded `.p8` is multi-line PEM and GitHub's masking needs a single-line exact match, so it would NOT be redacted — `testflight.yml` already forbids `set -x` in the signing step for exactly this reason. The same rule binds every step you add.
- Bundle id is `com.tylervick.waddle` (`App/project.yml:58`).
- Never weaken, delete, or skip an existing test. Current counts: `test-check-red-green.sh` 32, `test-loop-report.sh` 24, `test-loop-precheck.sh` 14, `test-check-simulator-available.sh` 8, `test-release-args.sh` 10. `check-substrate.sh` and `check-issue-format.sh` exit 0.
- Conventional commits, no `Co-Authored-By`, no Claude/AI mention. **Never write a bare `Closes #N` / `Fixes #N` / `Resolves #N` in a commit message** — a commit in this repo once closed a live issue that way.
- Commit with the repo default signing config. Do **not** override `gpg.ssh.program`; the owner's key lives in the 1Password agent. Retry up to 10 times at 15s intervals if it fails; report BLOCKED with work staged rather than bypassing signing.

---

## File Structure

| File | Responsibility |
|---|---|
| `Scripts/asc-jwt.sh` (create) | Mint one ES256 JWT for the ASC API. Nothing else. |
| `Scripts/test-asc-jwt.sh` (create) | Hermetic tests: JWT structure, DER→JOSE conversion. |
| `Scripts/whats-to-test.sh` (create) | Assemble notes text; attach to a build via the ASC API. |
| `Scripts/test-whats-to-test.sh` (create) | Hermetic tests: stub `git` and `curl`. |
| `docs/app-store/whats-to-test.md` (create) | Optional hand-written preamble. Ships empty. |
| `.github/workflows/testflight.yml` (modify) | Tag on upload success, then attach notes. |

---

### Task 1: `Scripts/asc-jwt.sh` — the ES256 JWT

**Files:**
- Create: `Scripts/asc-jwt.sh`, `Scripts/test-asc-jwt.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `Scripts/asc-jwt.sh` reading `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH` from the environment and printing one JWT on stdout. Task 3 calls it.

The DER→JOSE conversion is the whole difficulty. `openssl` emits an ASN.1 `SEQUENCE { INTEGER r, INTEGER s }`; JOSE needs raw `R‖S`, each left-padded to exactly 32 bytes. An `r` or `s` whose top bit is set carries a leading `0x00` in DER that must be stripped, and a short one must be padded — get either wrong and App Store Connect returns 401 with no explanation.

- [ ] **Step 1: Write the failing test**

Create `Scripts/test-asc-jwt.sh`:

```bash
#!/bin/bash
# Tests for Scripts/asc-jwt.sh.
#
# HERMETIC: generates its own throwaway EC key. Never reads the real
# App Store Connect key, and never contacts App Store Connect.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
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

echo "All asc-jwt tests passed."
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x Scripts/test-asc-jwt.sh && Scripts/test-asc-jwt.sh`
Expected: FAIL — `Scripts/asc-jwt.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `Scripts/asc-jwt.sh`:

```bash
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `chmod +x Scripts/asc-jwt.sh && Scripts/test-asc-jwt.sh`
Expected: 6 cases `ok -`, ending `All asc-jwt tests passed.`

- [ ] **Step 5: Commit**

```bash
git add Scripts/asc-jwt.sh Scripts/test-asc-jwt.sh
git commit -m "feat(release): mint an ES256 JWT for the App Store Connect API"
```

---

### Task 2: Notes assembly

**Files:**
- Create: `docs/app-store/whats-to-test.md`
- Modify: `Scripts/whats-to-test.sh` (create in this task), `Scripts/test-whats-to-test.sh` (create)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `Scripts/whats-to-test.sh --print` writing the assembled notes to stdout and exiting 0, or exiting non-zero with a diagnostic. Task 3 adds the attach path to the same script.

- [ ] **Step 1: Write the failing test**

Create `Scripts/test-whats-to-test.sh`:

```bash
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
# Signing and the user's global config are isolated -- see
# docs/learnings/git-fixtures-inherit-signing-config.md.
make_repo() { # name, mutate-script
    d="$TMP/$1"; mkdir -p "$d/docs/app-store" "$d/Scripts"; cd "$d"
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    git init -q .; git config user.email t@e.st; git config user.name T
    git config commit.gpgsign false; git config tag.gpgSign false
    cp "$ROOT/Scripts/whats-to-test.sh" Scripts/whats-to-test.sh
    chmod +x Scripts/whats-to-test.sh
    : > docs/app-store/whats-to-test.md
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
r="$(make_repo onlypre 'printf "Re-testing build 206 signing.\n" > docs/app-store/whats-to-test.md; git add -A; git commit -qm p')"
out="$(notes "$r")" || fail "should succeed on a preamble alone"
echo "$out" | grep -q "Re-testing build 206 signing." || fail "preamble missing; got: $out"
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

echo "All whats-to-test tests passed."
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x Scripts/test-whats-to-test.sh && Scripts/test-whats-to-test.sh`
Expected: FAIL — `Scripts/whats-to-test.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `Scripts/whats-to-test.sh`:

```bash
#!/bin/bash
# Assembles TestFlight "What to Test" notes and (in Task 3) attaches them to a
# build in App Store Connect.
#
# Usage:
#   Scripts/whats-to-test.sh --print            assemble and print, no network
#
# The notes are an optional hand-written preamble followed by a changelog
# computed from git. The changelog is DERIVED, not stored, and that is the
# point: a tracked notes file goes stale silently -- it is not empty, so an
# empty-check passes, and the build ships the previous release's text. A
# computed changelog cannot be stale. See
# docs/superpowers/specs/2026-08-11-whats-to-test-design.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PREAMBLE_FILE="docs/app-store/whats-to-test.md"

# The most recent build-* tag by version order, not by tag date: build numbers
# skip when a validate-only run consumes a run number, so lexical or
# chronological ordering would both pick the wrong anchor.
prev_tag() { git tag --list 'build-*' --sort=-v:refname 2>/dev/null | head -1; }

# One bullet per change. For a GitHub merge commit the useful title is the
# FIRST LINE OF THE BODY -- git's own subject is "Merge pull request #N from
# owner/branch", which tells a tester nothing. Direct commits use their
# subject. Both shapes occur in this repo.
changelog() { # range (may be empty, meaning "recent history")
    range="$1"
    while IFS= read -r sha; do
        [ -n "$sha" ] || continue
        subj="$(git log -1 --format=%s "$sha")"
        case "$subj" in
            "Merge pull request #"*)
                num="$(printf '%s' "$subj" | sed -n 's/^Merge pull request #\([0-9][0-9]*\).*/\1/p')"
                title="$(git log -1 --format=%b "$sha" | sed -n '1p')"
                [ -n "$title" ] || title="$subj"
                printf -- '- %s (#%s)\n' "$title" "$num"
                ;;
            *) printf -- '- %s\n' "$subj" ;;
        esac
    done < <(git log --first-parent --format=%H $range)
}

MODE="${1:---print}"
[ "$MODE" = "--print" ] || { echo "usage: $0 --print" >&2; exit 2; }

PREAMBLE=""
if [ -f "$PREAMBLE_FILE" ]; then
    PREAMBLE="$(sed -e 's/[[:space:]]*$//' "$PREAMBLE_FILE" | sed -e '/./,$!d')"
fi

TAG="$(prev_tag)"
NOTE=""
if [ -n "$TAG" ]; then
    HEADING="Changes since ${TAG#build-} $(printf '')"
    HEADING="Changes since build ${TAG#build-}:"
    BODY="$(changelog "$TAG..HEAD")"
else
    # Bootstrap: no release has ever been tagged. Failing here would block a
    # release for a condition that is true exactly once, so fall back -- but
    # disclose it, because the range is a guess rather than a fact.
    HEADING="Recent changes (no previous build tag; showing the last 20 commits):"
    BODY="$(changelog "--max-count=20")"
    NOTE="disclosed-fallback"
fi

if [ -z "$PREAMBLE" ] && [ -z "$BODY" ]; then
    echo "error: no changes since ${TAG:-the start of history} and $PREAMBLE_FILE is empty." >&2
    echo "       Nothing to tell a tester. Write a preamble or ship a build with changes in it." >&2
    exit 1
fi

if [ -n "$PREAMBLE" ]; then
    printf '%s\n' "$PREAMBLE"
    [ -n "$BODY" ] && printf '\n'
fi
if [ -n "$BODY" ]; then
    printf '%s\n' "$HEADING"
    printf '%s\n' "$BODY"
fi
```

- [ ] **Step 4: Create the preamble file**

```bash
mkdir -p docs/app-store
cat > docs/app-store/whats-to-test.md <<'EOF'
EOF
```

It ships empty on purpose: the derived changelog always carries content, so an empty preamble is the normal state. Write into it only when a release needs framing the commit log cannot supply.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `Scripts/test-whats-to-test.sh`
Expected: 7 cases `ok -`, ending `All whats-to-test tests passed.`

- [ ] **Step 6: Commit**

```bash
git add Scripts/whats-to-test.sh Scripts/test-whats-to-test.sh docs/app-store/whats-to-test.md
git commit -m "feat(release): assemble TestFlight notes from the commits since the last build"
```

---

### Task 3: Attach the notes via the App Store Connect API

**Files:**
- Modify: `Scripts/whats-to-test.sh`, `Scripts/test-whats-to-test.sh`

**Interfaces:**
- Consumes: `Scripts/asc-jwt.sh` from Task 1; the `--print` assembly from Task 2.
- Produces: `Scripts/whats-to-test.sh <build-number>` attaching the notes and exiting 0, or exiting non-zero with a diagnostic naming the build number. Task 4 calls this.

- [ ] **Step 1: Write the failing tests**

Append to `Scripts/test-whats-to-test.sh`, before the final `echo`:

```bash
# A curl stub driven by files, so each case chooses its own responses. It
# records every invocation so the tests can assert what was sent.
stub_curl() { # dir
    mkdir -p "$1/bin"
    cat > "$1/bin/curl" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUBDIR/curl.log"
for a in "$@"; do case "$a" in
    *"/v1/apps"*)                 cat "$STUBDIR/apps.json"; exit 0 ;;
    *"/v1/builds?"*)              cat "$STUBDIR/builds.json"; exit 0 ;;
    *"betaBuildLocalizations"*)   cat "$STUBDIR/loc.json"; exit 0 ;;
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

attach() { # dir, build-number
    (cd "$1" && env PATH="$1/bin:$PATH" STUBDIR="$1" ASC_JWT="$1/bin/asc-jwt.sh" \
        ASC_KEY_ID=K ASC_ISSUER_ID=I ASC_KEY_PATH=/dev/null \
        WHATS_TO_TEST_POLL_DELAY=0 \
        ./Scripts/whats-to-test.sh "$2" 2>&1)
}

# 8. No existing localization -> POST, and the notes text is sent.
r="$(make_repo attach_post 'merge_pr 90 "fix: a thing"')"; stub_curl "$r"
out="$(attach "$r" 207)" || fail "attach failed: $out"
grep -q "POST" "$r/curl.log" || fail "did not POST a new localization; log: $(cat "$r/curl.log")"
pass "creates a localization when none exists"

# 9. An existing en-US localization -> PATCH, never a duplicate POST.
r="$(make_repo attach_patch 'merge_pr 91 "fix: a thing"')"; stub_curl "$r"
printf '%s' '{"data":[{"id":"loc-1","attributes":{"locale":"en-US"}}]}' > "$r/loc.json"
out="$(attach "$r" 207)" || fail "attach failed: $out"
grep -q "PATCH" "$r/curl.log" || fail "did not PATCH the existing localization"
grep -q "POST" "$r/curl.log" && fail "POSTed a duplicate localization"
pass "patches an existing en-US localization instead of duplicating it"

# 10. A build stuck in PROCESSING past the cap fails, and the message names
#     the build number so the operator knows which build is affected.
r="$(make_repo attach_processing 'merge_pr 92 "fix: a thing"')"; stub_curl "$r"
printf '%s' '{"data":[{"id":"build-1","attributes":{"processingState":"PROCESSING"}}]}' > "$r/builds.json"
if out="$(env WHATS_TO_TEST_POLL_ATTEMPTS=2 attach "$r" 207)"; then
    fail "a build stuck in PROCESSING should fail"
fi
case "$out" in *207*) ;; *) fail "error does not name the build number; got: $out" ;; esac
pass "fails when the build never leaves PROCESSING, naming the build"

# 11. A build the API does not know about fails rather than attaching to
#     nothing.
r="$(make_repo attach_missing 'merge_pr 93 "fix: a thing"')"; stub_curl "$r"
printf '%s' '{"data":[]}' > "$r/builds.json"
if attach "$r" 207 >"$TMP/o11" 2>&1; then fail "should fail when the build is not found"; fi
grep -q "207" "$TMP/o11" || fail "error does not name the build; got: $(cat "$TMP/o11")"
pass "fails when App Store Connect does not have the build"
```

- [ ] **Step 2: Run to verify the new cases fail**

Run: `Scripts/test-whats-to-test.sh`
Expected: FAIL at case 8 — the script rejects any argument other than `--print`.

- [ ] **Step 3: Implement the attach path**

In `Scripts/whats-to-test.sh`, replace the `MODE` handling with a build-number mode, and add the API calls. Extract the assembly into a function so both modes share it:

```bash
API="https://api.appstoreconnect.apple.com"
BUNDLE_ID="com.tylervick.waddle"
# Overridable so the hermetic suite never really sleeps.
POLL_ATTEMPTS="${WHATS_TO_TEST_POLL_ATTEMPTS:-30}"
POLL_DELAY="${WHATS_TO_TEST_POLL_DELAY:-30}"
ASC_JWT="${ASC_JWT:-$ROOT/Scripts/asc-jwt.sh}"

# Extracts a top-level JSON string field from the first element of `data`.
# python3 stdlib rather than jq: jq is not guaranteed on a runner and this
# script must add no dependencies.
json_first() { # field-path e.g. "id" or "attributes.processingState"
    python3 -c '
import json, sys
doc = json.load(sys.stdin)
items = doc.get("data") or []
if not items:
    sys.exit(3)
cur = items[0]
for part in sys.argv[1].split("."):
    cur = (cur or {}).get(part)
print(cur if cur is not None else "")
' "$1"
}

api_get() { # path
    # Status tested directly, never masked: a failed call must not read as an
    # empty result. See docs/learnings/masked-exit-status-fails-open.md.
    curl -sS -f -H "Authorization: Bearer $TOKEN" "$API$1"
}
```

The attach flow, with each failure naming the build number:

```bash
BUILD="$MODE"
case "$BUILD" in ''|*[!0-9]*) echo "usage: $0 --print | <build-number>" >&2; exit 2 ;; esac

NOTES="$(assemble_notes)"   # the Task 2 logic, unchanged
TOKEN="$("$ASC_JWT")"

APP_ID="$(api_get "/v1/apps?filter%5BbundleId%5D=$BUNDLE_ID" | json_first id)" \
  || { echo "error: could not resolve the app id for $BUNDLE_ID" >&2; exit 1; }

attempt=1
while [ "$attempt" -le "$POLL_ATTEMPTS" ]; do
    RESP="$(api_get "/v1/builds?filter%5Bapp%5D=$APP_ID&filter%5Bversion%5D=$BUILD")"
    BUILD_ID="$(printf '%s' "$RESP" | json_first id || true)"
    STATE="$(printf '%s' "$RESP" | json_first attributes.processingState || true)"
    [ -n "$BUILD_ID" ] || { echo "error: App Store Connect has no build $BUILD for $BUNDLE_ID" >&2; exit 1; }
    [ "$STATE" = "PROCESSING" ] || break
    attempt=$((attempt + 1))
    [ "$attempt" -le "$POLL_ATTEMPTS" ] && sleep "$POLL_DELAY"
done
if [ "$STATE" = "PROCESSING" ]; then
    echo "error: build $BUILD is still PROCESSING after $POLL_ATTEMPTS attempts; notes not attached." >&2
    exit 1
fi
```

Then find an existing `en-US` localization and `PATCH` it, or `POST` a new one. Both shapes occur — a re-attach after a failure takes the `PATCH` path.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Scripts/test-whats-to-test.sh`
Expected: 11 cases `ok -`.

- [ ] **Step 5: Commit**

```bash
git add Scripts/whats-to-test.sh Scripts/test-whats-to-test.sh
git commit -m "feat(release): attach What-to-Test notes to a build via the ASC API"
```

---

### Task 4: Wire it into the release workflow

**Files:**
- Modify: `.github/workflows/testflight.yml`

**Interfaces:**
- Consumes: `Scripts/whats-to-test.sh <build-number>` from Task 3.
- Produces: a tag `build-<N>` per successful upload, and notes attached to that build.

- [ ] **Step 1: Grant the job a tag push**

The job is `permissions: contents: read` today. Change it to `contents: write`, with a comment stating it is for the `build-<N>` tag and nothing else.

- [ ] **Step 2: Tag after a confirmed upload**

Insert after the existing "Upload to TestFlight" step:

```yaml
      # Tag BEFORE attaching notes, and only on a real upload. The tag records
      # what shipped, and the NEXT release computes its changelog range from
      # it. If the tag were gated on the notes succeeding, a notes failure
      # would leave the next release anchored on an older build and silently
      # re-list changes already delivered.
      - name: Tag the shipped build
        if: ${{ inputs.validate_only != true }}
        env:
          N: ${{ steps.buildnum.outputs.value }}
        run: |
          git tag "build-$N"
          git push origin "build-$N"
```

- [ ] **Step 3: Attach the notes**

```yaml
      # Notes are metadata: a failure here does NOT mean the release failed.
      # It fails the job anyway, loudly, because a silent warning is how the
      # field ends up empty -- which is the entire reason this exists.
      - name: Attach What to Test notes
        if: ${{ inputs.validate_only != true }}
        env:
          ASC_KEY_PATH: ${{ runner.temp }}/AuthKey_${{ secrets.ASC_KEY_ID }}.p8
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
          N: ${{ steps.buildnum.outputs.value }}
        run: |
          if ! Scripts/whats-to-test.sh "$N"; then
            echo "::error::Build $N IS UPLOADED and the release did NOT fail --"
            echo "::error::only the What-to-Test notes could not be attached."
            echo "::error::Re-running this workflow will REBUILD AND UPLOAD AGAIN,"
            echo "::error::consuming another build number. The build_number input"
            echo "::error::cannot avoid that: App Store Connect rejects a duplicate."
            echo "::error::Set the notes by hand in App Store Connect instead."
            exit 1
          fi
```

The message is the point. A red run whose obvious remedy is destructive has to say so at the moment of failure.

- [ ] **Step 4: Verify the workflow parses**

Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/testflight.yml"); puts "testflight.yml OK"'`
Expected: `testflight.yml OK`

- [ ] **Step 5: Verify the suites still pass**

Run: `Scripts/test-asc-jwt.sh && Scripts/test-whats-to-test.sh && Scripts/check-substrate.sh && echo GREEN`
Expected: 6 then 11 `ok -` lines, then `GREEN`.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/testflight.yml
git commit -m "ci(release): tag each shipped build and attach its What-to-Test notes"
```

---

## Self-Review

**Spec coverage.** Preamble + derived changelog → Task 2. Staleness impossibility → Task 2 (derived half). Tag anchor and its ordering → Task 4 Step 2. ES256 JWT without PyJWT → Task 1. App id resolution, build lookup, `PROCESSING` poll with a 15-minute cap (30 attempts × 30s), `POST`/`PATCH` → Task 3. Loud failure naming the build and the re-run cost → Task 4 Step 3. Empty-changelog-and-empty-preamble failure → Task 2 case 4. Missing-tag bootstrap fallback with disclosure → Task 2 case 6. Hermetic tests stubbing `git`/`curl` → Tasks 1–3. `validate_only` skips both new steps → Task 4.

**Not covered, deliberately:** the real API contract. Stubs assert what this sends, not what App Store Connect accepts; the spec says so and the first live run is the real test.

**Placeholder scan:** one dead line was left in Task 2's draft (`HEADING="Changes since ${TAG#build-} $(printf '')"`, immediately overwritten). The implementer should delete it rather than reproduce it; it is noted here rather than silently fixed so the discrepancy between plan text and intent is visible.

**Type consistency.** `assemble_notes` is named in Task 3 as the extraction of Task 2's assembly logic; `prev_tag`, `changelog`, `json_first`, `api_get` keep their signatures across tasks. `ASC_JWT`, `WHATS_TO_TEST_POLL_ATTEMPTS`, `WHATS_TO_TEST_POLL_DELAY` are declared once in Task 3 and used only there.
