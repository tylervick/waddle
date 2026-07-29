#!/bin/bash
# Tests for Scripts/check-engine-fresh.sh.
#
# Fully HERMETIC: builds a fake repo in a temp dir and runs the guard there.
# Nothing here touches the real Vendor/ tree.
#
# The guard deliberately lives in its own script rather than inline in
# archive.sh precisely so this test can exist: archive.sh continues past the
# guard into xcodegen, a full Release build, `rm -rf Vendor/archive/export`,
# and a signed export. Exercising the guard's SUCCESS path through archive.sh
# would either run that whole build or require stubbing xcodebuild -- which
# cannot work, because archive.sh re-invokes it as `PATH="/usr/bin:$PATH"
# xcodebuild` and would find the real binary ahead of any stub, and because
# the `rm -rf` would destroy real local artifacts on the way past.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# Fake repo mirroring the real layout the guard and fingerprint walk.
make_fixture() { # dest
    mkdir -p "$1/Scripts" "$1/Engine/woof/src" "$1/Vendor/out"
    cp "$ROOT/Scripts/engine-fingerprint.sh"  "$1/Scripts/"
    cp "$ROOT/Scripts/check-engine-fresh.sh"  "$1/Scripts/"
    echo 'stub build-engine' > "$1/Scripts/build-engine.sh"
    echo 'stub build-deps'   > "$1/Scripts/build-deps.sh"
    echo 'int main(void){}'  > "$1/Engine/woof/src/d_main.c"
    # A directory is all the guard checks for -- it never opens the framework.
    mkdir -p "$1/Vendor/out/WoofEngine.xcframework"
}
stamp()  { "$1/Scripts/engine-fingerprint.sh" > "$1/Vendor/out/WoofEngine.xcframework.fingerprint"; }
check()  { "$1/Scripts/check-engine-fresh.sh"; }

# 1. Framework missing entirely -> refuse, and say how to build it.
make_fixture "$TMP/a"; stamp "$TMP/a"; rm -rf "$TMP/a/Vendor/out/WoofEngine.xcframework"
if check "$TMP/a" >"$TMP/out" 2>&1; then fail "passed with no framework"; fi
grep -q "build the engine first" "$TMP/out" || fail "missing-framework error lacks build guidance"
pass "fails closed when the framework is missing"

# 2. Framework present but never stamped -> refuse.
make_fixture "$TMP/b"
if check "$TMP/b" >"$TMP/out" 2>&1; then fail "passed with no stamp file"; fi
grep -q "rebuild before archiving" "$TMP/out" || fail "missing-stamp error lacks rebuild guidance"
pass "fails closed when the stamp is missing"

# 3. Stamp that does not match current content -> refuse.
make_fixture "$TMP/c"; stamp "$TMP/c"
echo 'edited after the build' >> "$TMP/c/Engine/woof/src/d_main.c"
if check "$TMP/c" >"$TMP/out" 2>&1; then fail "passed with a stale stamp"; fi
grep -q "rebuild before archiving" "$TMP/out" || fail "mismatch error lacks rebuild guidance"
pass "fails closed when sources changed since the build"

# 4. A build-script edit also invalidates, not just engine sources.
make_fixture "$TMP/d"; stamp "$TMP/d"
echo 'x' >> "$TMP/d/Scripts/build-deps.sh"
if check "$TMP/d" >"$TMP/out" 2>&1; then fail "passed after build-deps.sh changed"; fi
pass "fails closed when a build script changed"

# 5. Matching stamp -> pass, silently.
make_fixture "$TMP/e"; stamp "$TMP/e"
check "$TMP/e" >"$TMP/out" 2>&1 || fail "refused a valid stamp: $(cat "$TMP/out")"
[ ! -s "$TMP/out" ] || fail "should be silent on success, printed: $(cat "$TMP/out")"
pass "passes silently when the stamp matches"

# 6. THE REGRESSION THIS REPLACES. Content is byte-identical, but every
#    engine source now has an mtime NEWER than the framework -- exactly what
#    a fresh worktree checkout or a restored CI cache produces. The old
#    `find -newer` guard fired here and demanded a ~25-minute rebuild that
#    would have changed nothing.
make_fixture "$TMP/f"; stamp "$TMP/f"
touch "$TMP/f/Engine/woof/src/d_main.c" "$TMP/f/Scripts/build-deps.sh"
check "$TMP/f" >"$TMP/out" 2>&1 || fail "tripped on newer mtimes despite identical content"
pass "ignores mtimes when content is unchanged (fresh-worktree regression)"

# 7. Unreadable sources -> refuse, rather than passing on a failed compare.
make_fixture "$TMP/g"; stamp "$TMP/g"; rm -rf "$TMP/g/Engine/woof"
if check "$TMP/g" >"$TMP/out" 2>&1; then fail "passed when sources could not be read"; fi
grep -q "could not fingerprint" "$TMP/out" || fail "refused via the wrong branch; expected the fingerprint-failure path"
pass "fails closed when the fingerprint cannot be computed"

echo "All check-engine-fresh tests passed."
