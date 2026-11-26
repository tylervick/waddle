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
# The stall case takes a little over 30 s: that is the stall guard firing.
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
REL="$TMP/release"
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
#
# /release/<f> serves $REL as it is. Two more prefixes misbehave on the FIRST
# request for a .zip only, then serve it properly, and log every request to
# $TMP/hits so a case can count attempts:
#   /drop/<f>  promises the whole file, sends half and closes the connection
#              (curl: exit 18, "transfer closed with N bytes remaining");
#   /stall/<f> promises the whole file, sends a few bytes and then nothing for
#              STALL_SECONDS, longer than the stall guard allows.
# Threaded, so a retry is answered while the first request is still stalled.
python3 - "$REL" "$TMP/port" "$TMP/hits" <<'PY2' > "$TMP/server.log" 2>&1 &
import http.server, os, sys, threading, time
rel, port_file, hits_file = sys.argv[1:4]
STALL_SECONDS = 75
seen, lock = set(), threading.Lock()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        mode, _, name = self.path.lstrip("/").partition("/")
        path = os.path.join(rel, name)
        with lock:
            with open(hits_file, "a") as f:
                f.write(self.path + "\n")
            first = (mode, name) not in seen
            seen.add((mode, name))
        if mode not in ("release", "drop", "stall") or not os.path.isfile(path):
            self.send_error(404)
            return
        body = open(path, "rb").read()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        misbehave = first and name.endswith(".zip") and mode != "release"
        if misbehave and mode == "drop":
            self.wfile.write(body[: len(body) // 2])
            self.wfile.flush()
            self.close_connection = True
            return
        if misbehave and mode == "stall":
            self.wfile.write(body[:8])
            self.wfile.flush()
            time.sleep(STALL_SECONDS)
            self.close_connection = True
            return
        self.wfile.write(body)

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
with open(port_file + ".tmp", "w") as f:
    f.write(str(server.server_address[1]))
os.rename(port_file + ".tmp", port_file)
server.serve_forever()
PY2
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
# --retry-all-errors retries this too (plain --retry would not), so it is
# exactly 6 attempts: bounded, and each with curl's own 404 line.
C="$TMP/c"; make_fixture "$C" "http://127.0.0.1:$PORT/no-such-release"
SECONDS=0
run_fetch "$C"
[ "$RC" -ne 0 ] || fail "a 404 succeeded"
n="$(grep -c "returned error: 404" "$TMP/run.log" || true)"
[ "$n" -eq 6 ] || fail "expected exactly 6 attempts on a 404, saw $n: $(cat "$TMP/run.log")"
[ "$SECONDS" -le 30 ] || fail "a 404 took ${SECONDS}s to fail"
[ ! -e "$C/App/Resources/GameData" ] || fail "a 404 staged something"
pass "fails a 404 after $n attempts, ${SECONDS}s in all (exit $RC)"

# Counts the server's requests for $1 (a path), since the last reset.
hits() { grep -cxF "$1" "$TMP/hits" || true; }

# --- 4. a transfer dropped part-way is retried into a whole file --------
# The failure --retry-all-errors exists for: the connection is made and then
# lost mid-body. Plain --retry does not retry it; curl exits 18 at once.
: > "$TMP/hits"
F="$TMP/f"; make_fixture "$F" "http://127.0.0.1:$PORT/drop"
run_fetch "$F"
[ "$RC" -eq 0 ] || fail "a dropped transfer was not retried (exit $RC): $(cat "$TMP/run.log")"
n="$(hits "/drop/$ZIP")"
[ "$n" -eq 2 ] || fail "expected 2 requests for the dropped zip, saw $n"
grep -qx "OK" "$TMP/run.log" || fail "the retried download did not pass the checksum"
[ "$(unzip -p "$REL/$ZIP" "freedoom-$VERSION/freedoom2.wad")" = "$(cat "$F/App/Resources/GameData/freedoom2.wad")" ] \
    || fail "the staged WAD is not the whole file"
pass "retries a transfer dropped part-way and stages the whole file"

# --- 5. a transfer that stalls is abandoned and retried -----------------
# The server sends 8 bytes and then nothing for 75 s. The stall guard (under
# 1000 bytes/s for 30 s) abandons it with exit 28 and the retry completes, so
# this takes a little over 30 s; without the guard it would sit out all 75.
: > "$TMP/hits"
G="$TMP/g"; make_fixture "$G" "http://127.0.0.1:$PORT/stall"
SECONDS=0
run_fetch "$G"
[ "$RC" -eq 0 ] || fail "a stalled transfer was not retried (exit $RC): $(cat "$TMP/run.log")"
[ "$SECONDS" -lt 60 ] || fail "a stalled transfer took ${SECONDS}s -- the stall guard did not fire"
n="$(hits "/stall/$ZIP")"
[ "$n" -eq 2 ] || fail "expected 2 requests for the stalled zip, saw $n"
grep -q "Operation too slow" "$TMP/run.log" || fail "curl did not report the stall: $(cat "$TMP/run.log")"
pass "abandons a stalled transfer after the guard's 30 s and retries it (${SECONDS}s in all)"

# --- 6. a checksum mismatch still fails, at once, as it did -------------
# The download succeeds, so nothing is retried; the bytes are wrong.
printf 'SHA256 (%s) = %s\n' "$ZIP" "$(printf '0%.0s' $(seq 1 64))" > "$REL/freedoom-$VERSION-CHECKSUM"
D="$TMP/d"; make_fixture "$D" "http://127.0.0.1:$PORT/release"
run_fetch "$D"
[ "$RC" -eq 1 ] || fail "a checksum mismatch exited $RC, not 1: $(cat "$TMP/run.log")"
grep -qxF "ERROR: Checksum mismatch for $ZIP" "$TMP/run.log" \
    || fail "the mismatch message changed: $(cat "$TMP/run.log")"
[ ! -e "$D/App/Resources/GameData" ] || fail "a mismatched download staged something"
pass "refuses a checksum mismatch with the same message"

# --- 7. a CHECKSUM without the pinned zip's line still fails ------------
printf 'SHA256 (some-other.zip) = %s\n' "$HASH" > "$REL/freedoom-$VERSION-CHECKSUM"
E="$TMP/e"; make_fixture "$E" "http://127.0.0.1:$PORT/release"
run_fetch "$E"
[ "$RC" -eq 1 ] || fail "a CHECKSUM missing the zip's hash exited $RC, not 1"
grep -qxF "ERROR: Could not extract hash from CHECKSUM file" "$TMP/run.log" \
    || fail "the missing-hash message changed: $(cat "$TMP/run.log")"
pass "refuses a CHECKSUM that does not name the pinned zip"

echo "all fetch-freedoom tests passed"
