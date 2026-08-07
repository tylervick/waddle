#!/bin/bash
# Tests for Scripts/check-issue-format.sh.
#
# Fully HERMETIC: builds a fake repo in a temp dir and runs the guard there.
# Nothing here touches real GitHub issues.
#
# Runs with PATH stripped to /usr/bin:/bin so `gh` is invisible, and with
# GH_TOKEN/GITHUB_TOKEN cleared and GH_CONFIG_DIR pointed at a nonexistent
# directory so a `gh` that does exist there -- e.g. a future macOS image that
# ships one at /usr/bin/gh -- still can't authenticate. This check's own
# workflow sets GH_TOKEN at the step level, and without clearing it here that
# token would leak into the "no gh" fixture below and run the real,
# authenticated `gh` against a directory that isn't a git repo, breaking case
# 1. That is deliberate: it pins the check's skip path, which is the
# behaviour CI depends on when no token is present, and it keeps the whole
# suite offline and deterministic. The one exception is case 2, which needs
# `gh` to appear installed and authenticated so it can reach the
# query-failure path; it prepends a fixture bin/ directory containing a stub
# `gh` instead, bypassing check() (and its cleared credentials) entirely.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# Fake repo mirroring the layout the guard walks.
make_fixture() { # dest
    mkdir -p "$1/Scripts"
    cp "$ROOT/Scripts/check-issue-format.sh" "$1/Scripts/"
}
check() { env PATH=/usr/bin:/bin GH_TOKEN= GITHUB_TOKEN= GH_CONFIG_DIR=/nonexistent "$1/Scripts/check-issue-format.sh"; }

# 1. gh missing or unauthenticated -> skip cleanly, exit 0.
make_fixture "$TMP/a"
check "$TMP/a" >"$TMP/out" 2>&1 || fail "refused when gh is unavailable: $(cat "$TMP/out")"
grep -q "^skip - " "$TMP/out" || fail "did not report the gh skip; got: $(cat "$TMP/out")"
pass "skips cleanly and exits 0 when gh is missing or unauthenticated"

# 2. gh installed and authenticated, but the issue query itself fails (bad
#    token scope, network error, rate limit, wrong cwd) -> refuse, rather than
#    the `for n in $(gh issue list ...)` construct swallowing the
#    substitution's exit status under set -e and passing silently.
make_fixture "$TMP/b"
mkdir -p "$TMP/b/bin"
cat > "$TMP/b/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
    echo "gh: rate limited" >&2
    exit 1
fi
echo "unexpected stub gh invocation: $*" >&2
exit 1
STUB
chmod +x "$TMP/b/bin/gh"
if env PATH="$TMP/b/bin:/usr/bin:/bin" "$TMP/b/Scripts/check-issue-format.sh" >"$TMP/out" 2>&1
then
    fail "passed when gh issue list itself failed"
fi
grep -q "gh issue list failed" "$TMP/out" || fail "issue-list-failure error unclear"
pass "fails when gh issue list itself fails, rather than passing silently"

echo "All check-issue-format tests passed."
