#!/bin/bash
# Tests for Scripts/engine-fingerprint.sh.
#
# Most assertions run against a HERMETIC fake repo built in a temp dir --
# the fingerprint's whole job is to change when inputs change, and proving
# that requires mutating inputs. Doing that in the real tree would risk
# leaving the working copy dirty if the script aborts partway.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/Scripts/engine-fingerprint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# --- hermetic fixture -------------------------------------------------
# Mirrors the real layout the script walks: Engine/woof/** plus the two
# build scripts. Contents are stubs; only their bytes matter here.
make_fixture() { # dest
    mkdir -p "$1/Scripts" "$1/Engine/woof/src" "$1/Engine/woof/third-party"
    cp "$SCRIPT" "$1/Scripts/engine-fingerprint.sh"
    echo 'stub build-engine' > "$1/Scripts/build-engine.sh"
    echo 'stub build-deps'   > "$1/Scripts/build-deps.sh"
    echo 'int main(void){}'  > "$1/Engine/woof/src/d_main.c"
    echo 'add_subdirectory(x)' > "$1/Engine/woof/third-party/CMakeLists.txt"
}
fp() { "$1/Scripts/engine-fingerprint.sh"; } # repo-root -> hash

make_fixture "$TMP/a"
BASE="$(fp "$TMP/a")"

# 1. Well-formed output: exactly one 64-char lowercase hex line.
[[ "$BASE" =~ ^[0-9a-f]{64}$ ]] || fail "not a 64-char hex hash: '$BASE'"
pass "emits a 64-char lowercase hex hash"

# 2. Deterministic across repeated runs with no edits.
[ "$(fp "$TMP/a")" = "$BASE" ] || fail "not deterministic across runs"
pass "deterministic across repeated runs"

# 3. Path-independent: same content at a different path -> same hash.
#    This is what lets a worktree, a fresh clone, and the CI checkout dir
#    all agree, and it is why the script hashes repo-RELATIVE paths.
make_fixture "$TMP/b-different-name"
[ "$(fp "$TMP/b-different-name")" = "$BASE" ] || fail "hash depends on checkout path"
pass "path-independent"

# 4. Independent of the caller's working directory.
[ "$(cd / && fp "$TMP/a")" = "$BASE" ] || fail "hash depends on caller cwd"
pass "independent of caller cwd"

# 5. Sensitive to an edit anywhere under Engine/woof -- including OUTSIDE
#    src/, which the old mtime guard did not watch at all.
echo 'changed' >> "$TMP/a/Engine/woof/src/d_main.c"
[ "$(fp "$TMP/a")" != "$BASE" ] || fail "ignored an edit under Engine/woof/src"
pass "detects edits under Engine/woof/src"

make_fixture "$TMP/c"
echo 'changed' >> "$TMP/c/Engine/woof/third-party/CMakeLists.txt"
[ "$(fp "$TMP/c")" != "$BASE" ] || fail "ignored an edit outside Engine/woof/src"
pass "detects edits elsewhere under Engine/woof"

# 6. Sensitive to either build script.
make_fixture "$TMP/d"; echo 'x' >> "$TMP/d/Scripts/build-deps.sh"
[ "$(fp "$TMP/d")" != "$BASE" ] || fail "ignored an edit to build-deps.sh"
pass "detects edits to build-deps.sh"

make_fixture "$TMP/e"; echo 'x' >> "$TMP/e/Scripts/build-engine.sh"
[ "$(fp "$TMP/e")" != "$BASE" ] || fail "ignored an edit to build-engine.sh"
pass "detects edits to build-engine.sh"

# 7. Sensitive to a NEW file (not just edits to known ones).
make_fixture "$TMP/f"; echo 'new' > "$TMP/f/Engine/woof/src/new_file.c"
[ "$(fp "$TMP/f")" != "$BASE" ] || fail "ignored a newly added engine source"
pass "detects newly added engine sources"

# 8. Fails CLOSED when the engine tree is missing, rather than printing
#    the hash of an empty set -- which would silently validate any stamp.
make_fixture "$TMP/g"; rm -rf "$TMP/g/Engine/woof"
if fp "$TMP/g" >/dev/null 2>&1; then fail "succeeded with Engine/woof missing"; fi
pass "fails closed when Engine/woof is missing"

# 8b. Fails CLOSED when Engine/woof exists but is EMPTY, too -- `find`
#     exits 0 over an empty directory and BSD xargs never invokes shasum,
#     so without an explicit count check this would silently emit a clean
#     hash over just the two build scripts instead of aborting.
make_fixture "$TMP/i"; rm -rf "$TMP/i/Engine/woof"/*; mkdir -p "$TMP/i/Engine/woof"
if fp "$TMP/i" >/dev/null 2>&1; then fail "succeeded with Engine/woof empty"; fi
pass "fails closed when Engine/woof is empty"

make_fixture "$TMP/h"; rm -f "$TMP/h/Scripts/build-deps.sh"
if fp "$TMP/h" >/dev/null 2>&1; then fail "succeeded with build-deps.sh missing"; fi
pass "fails closed when a build script is missing"

# --- real repo --------------------------------------------------------
# The fixture is tiny; confirm the properties hold over the real 761-file
# tree too, and that it stays fast enough for archive.sh to call inline.
REAL="$("$SCRIPT")"
[[ "$REAL" =~ ^[0-9a-f]{64}$ ]] || fail "real repo: malformed hash"
[ "$(cd / && "$SCRIPT")" = "$REAL" ] || fail "real repo: cwd-dependent"
pass "real repo: well-formed and cwd-independent"

echo "All engine-fingerprint tests passed."
