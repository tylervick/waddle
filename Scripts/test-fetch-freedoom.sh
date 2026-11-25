#!/bin/bash
# Tests for Scripts/fetch-freedoom.sh (issue #531).
#
# The real script, copied with its release URL repointed, run against the REAL
# curl: what is under test is curl's own retry behaviour with the flags the
# script passes, which a curl stub could only echo back. Nothing here reaches
# GitHub. The release is served by a throwaway python3 HTTP server on
# localhost, and the resolve case uses a .invalid name (RFC 6761), which never
# resolves. The rewrite asserts it applied, so renaming the URL upstream turns
# this into a loud failure instead of a quiet network test.
#
# The cases that fail take about 10 s each: that is the bounded retry itself.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/Scripts/fetch-freedoom.sh"
TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        # Reaped here so bash does not print "Terminated" for it at exit.
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# Which curl answered matters (its retry rules have changed across versions),
# so the log of every run records it.
echo "# $(curl --version | sed -n '1p')"

VERSION="$(sed -n 's/^FREEDOOM_VERSION="\(.*\)"$/\1/p' "$SCRIPT")"
[ -n "$VERSION" ] || fail "could not read FREEDOOM_VERSION from $SCRIPT"
ZIP="freedoom-$VERSION.zip"

# --- a fake release ---------------------------------------------------
# Laid out like the real zip: the WADs and the licence one directory down.
REL="$TMP/www/release"
mkdir -p "$REL"
python3 - "$REL/$ZIP" "$VERSION" <<'PY'
import sys, zipfile
path, version = sys.argv[1], sys.argv[2]
top = f"freedoom-{version}/"
with zipfile.ZipFile(path, "w") as z:
    z.writestr(top + "freedoom1.wad", "IWAD one")
    z.writestr(top + "freedoom2.wad", "IWAD two")
    z.writestr(top + "COPYING.txt", "licence")
PY
HASH="$(shasum -a 256 "$REL/$ZIP" | awk '{print $1}')"
printf 'SHA256 (%s) = %s\n' "$ZIP" "$HASH" > "$REL/freedoom-$VERSION-CHECKSUM"

# A localhost server on a port the kernel picks; it writes the port once it
# is listening, so there is no race and no fixed port to collide on.
python3 - "$TMP/www" "$TMP/port" <<'PY' > "$TMP/server.log" 2>&1 &
import functools, http.server, sys
root, port_file = sys.argv[1], sys.argv[2]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
server = http.server.HTTPServer(("127.0.0.1", 0), handler)
with open(port_file + ".tmp", "w") as f:
    f.write(str(server.server_address[1]))
import os; os.rename(port_file + ".tmp", port_file)
server.serve_forever()
PY
SERVER_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
[ -s "$TMP/port" ] || fail "the fixture HTTP server did not start: $(cat "$TMP/server.log")"
PORT="$(cat "$TMP/port")"

# A copy of the REAL script with BASE repointed at $1, staging into its own
# App/Resources/GameData.
make_fixture() { # dest base-url
    mkdir -p "$1/Scripts"
    sed "s|^BASE=\"https://github.com/freedoom/freedoom/releases/download/v\${FREEDOOM_VERSION}\"$|BASE=\"$2\"|" \
        "$SCRIPT" > "$1/Scripts/fetch-freedoom.sh"
    chmod +x "$1/Scripts/fetch-freedoom.sh"
    grep -qxF "BASE=\"$2\"" "$1/Scripts/fetch-freedoom.sh" \
        || fail "fixture did not repoint BASE -- this test would hit the network"
}

# Runs the fixture; sets RC and leaves the combined output in $TMP/run.log.
run_fetch() { # fixture
    RC=0
    "$1/Scripts/fetch-freedoom.sh" > "$TMP/run.log" 2>&1 || RC=$?
}

# --- 1. a good release is verified and staged -------------------------
A="$TMP/a"; make_fixture "$A" "http://127.0.0.1:$PORT/release"
run_fetch "$A"
[ "$RC" -eq 0 ] || fail "a good release failed (exit $RC): $(cat "$TMP/run.log")"
grep -qx "OK" "$TMP/run.log" || fail "the checksum check did not report OK"
for f in freedoom1.wad freedoom2.wad FREEDOOM-COPYING.txt; do
    [ -f "$A/App/Resources/GameData/$f" ] || fail "$f was not staged"
done
pass "verifies and stages a good release"

# --- 2. a host that does not resolve is retried, then fails -----------
# The failure seen on the runner (curl exit 6). 5 retries means 6 attempts,
# each printing curl's own line.
B="$TMP/b"; make_fixture "$B" "https://freedoom-fixture.invalid/release"
SECONDS=0
run_fetch "$B"
[ "$RC" -ne 0 ] || fail "an unresolvable host succeeded"
n="$(grep -c "Could not resolve host" "$TMP/run.log" || true)"
[ "$n" -eq 6 ] || fail "expected 6 attempts on a resolve failure, saw $n: $(cat "$TMP/run.log")"
[ "$SECONDS" -ge 8 ] || fail "6 attempts took ${SECONDS}s -- the retry delay is not being applied"
[ ! -e "$B/App/Resources/GameData" ] || fail "a failed download staged something"
pass "retries a resolve failure 5 times, ${SECONDS}s in all, then fails (exit $RC)"

# --- 3. a 404 is bounded, and fails with curl's 404 message -------------
# --retry-all-errors retries this too; what matters is that it stops.
C="$TMP/c"; make_fixture "$C" "http://127.0.0.1:$PORT/no-such-release"
SECONDS=0
run_fetch "$C"
[ "$RC" -ne 0 ] || fail "a 404 succeeded"
n="$(grep -c "returned error: 404" "$TMP/run.log" || true)"
[ "$n" -ge 1 ] && [ "$n" -le 6 ] || fail "expected 1 to 6 attempts on a 404, saw $n: $(cat "$TMP/run.log")"
[ "$SECONDS" -le 30 ] || fail "a 404 took ${SECONDS}s to fail"
[ ! -e "$C/App/Resources/GameData" ] || fail "a 404 staged something"
pass "fails a 404 after $n attempts, ${SECONDS}s in all (exit $RC)"

# --- 4. a checksum mismatch still fails, at once, as it did -------------
# The download succeeds, so nothing is retried; the bytes are wrong.
printf 'SHA256 (%s) = %s\n' "$ZIP" "$(printf '0%.0s' $(seq 1 64))" > "$REL/freedoom-$VERSION-CHECKSUM"
D="$TMP/d"; make_fixture "$D" "http://127.0.0.1:$PORT/release"
run_fetch "$D"
[ "$RC" -eq 1 ] || fail "a checksum mismatch exited $RC, not 1: $(cat "$TMP/run.log")"
grep -qxF "ERROR: Checksum mismatch for $ZIP" "$TMP/run.log" \
    || fail "the mismatch message changed: $(cat "$TMP/run.log")"
[ ! -e "$D/App/Resources/GameData" ] || fail "a mismatched download staged something"
pass "refuses a checksum mismatch with the same message"

# --- 5. a CHECKSUM without the pinned zip's line still fails ------------
printf 'SHA256 (some-other.zip) = %s\n' "$HASH" > "$REL/freedoom-$VERSION-CHECKSUM"
E="$TMP/e"; make_fixture "$E" "http://127.0.0.1:$PORT/release"
run_fetch "$E"
[ "$RC" -eq 1 ] || fail "a CHECKSUM missing the zip's hash exited $RC, not 1"
grep -qxF "ERROR: Could not extract hash from CHECKSUM file" "$TMP/run.log" \
    || fail "the missing-hash message changed: $(cat "$TMP/run.log")"
pass "refuses a CHECKSUM that does not name the pinned zip"

echo "all fetch-freedoom tests passed"
