#!/bin/bash
# Tests for Scripts/ensure-native-cmake-cache.sh (issue #72).
#
# Fully HERMETIC: every build directory is a fixture under $TMP with a
# hand-written CMakeCache.txt. Nothing here runs cmake or touches Vendor/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/Scripts/ensure-native-cmake-cache.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# A build directory with the cache CMake would have written for `cachedir`,
# plus a sentinel that only survives if the directory was left alone.
make_build_dir() { # dir cachedir
    mkdir -p "$1"
    cat > "$1/CMakeCache.txt" <<EOF
# This is the CMakeCache file.
CMAKE_BUILD_TYPE:STRING=Release
CMAKE_CACHEFILE_DIR:INTERNAL=$2
CMAKE_HOME_DIRECTORY:INTERNAL=$2/../../Engine/woof
EOF
    touch "$1/.sentinel"
}

run_guard() { # dirs...
    "$SCRIPT" "$@" > "$TMP/run.log" 2>&1 || { cat "$TMP/run.log" >&2; fail "guard exited non-zero"; }
}

# --- 1. the bug in #72: a cache seeded from another checkout ------------
# Its CMAKE_CACHEFILE_DIR names the OTHER checkout's build directory. cmake
# refuses to configure on top of it, so the guard must remove the directory
# and say so, and the build then configures from scratch.
mkdir -p "$TMP/other/Vendor/build/woof-iphoneos"
A="$TMP/a/Vendor/build/woof-iphoneos"
make_build_dir "$A" "$TMP/other/Vendor/build/woof-iphoneos"
run_guard "$A"
[ ! -e "$A" ] || fail "a cache pointing at another checkout was kept"
grep -q "woof-iphoneos" "$TMP/run.log" || fail "clearing a foreign cache printed no note: $(cat "$TMP/run.log")"
pass "removes a build directory whose cache belongs to another checkout"

# --- 2. a cache that is this checkout's own --------------------------
# Re-configuring from scratch on every build would trade three minutes once
# for time lost on every build; a matching cache must be left alone.
B="$TMP/b/Vendor/build/SDL-iphoneos"
make_build_dir "$B" "$B"
run_guard "$B"
[ -f "$B/.sentinel" ] || fail "a cache that matches its own directory was discarded"
[ ! -s "$TMP/run.log" ] || fail "a matching cache produced output: $(cat "$TMP/run.log")"
pass "leaves a build directory alone when its cache names itself"

# --- 3. the path is compared physically, not textually ----------------
# A worktree that symlinks Vendor at the primary checkout shares the primary's
# build directories, and their caches name the primary's real path. Reached
# through the symlink the directory IS that path, so it is not foreign; a
# string comparison against the symlinked spelling would clear a valid cache
# on every build.
mkdir -p "$TMP/primary/Vendor/build"
C="$TMP/primary/Vendor/build/openal-soft-iphonesimulator"
make_build_dir "$C" "$(cd "$TMP/primary/Vendor/build" && pwd -P)/openal-soft-iphonesimulator"
mkdir -p "$TMP/worktree"
ln -s "$TMP/primary/Vendor" "$TMP/worktree/Vendor"
run_guard "$TMP/worktree/Vendor/build/openal-soft-iphonesimulator"
[ -f "$C/.sentinel" ] || fail "a shared cache reached through a Vendor symlink was discarded"
pass "keeps a cache reached through a symlink when it names the same physical directory"

# --- 4. a build directory that has never been configured ---------------
# No CMakeCache.txt means nothing to disagree with; cmake will configure it.
# An interrupted first configure leaves exactly this behind, and removing it
# would be harmless but is not the guard's job -- it must not touch it.
D="$TMP/d/Vendor/build/ogg-iphoneos"
mkdir -p "$D"; touch "$D/.sentinel"
run_guard "$D"
[ -f "$D/.sentinel" ] || fail "an unconfigured build directory was removed"
pass "leaves an unconfigured build directory alone"

# --- 5. a directory that does not exist -------------------------------
# The first build of a fresh checkout: every directory is absent. The guard
# must succeed silently rather than fail on a missing argument.
run_guard "$TMP/e/Vendor/build/vorbis-iphoneos"
[ ! -e "$TMP/e" ] || fail "a missing build directory was created"
pass "succeeds when the build directory does not exist yet"

# --- 6. a cache with no CMAKE_CACHEFILE_DIR at all --------------------
# A truncated or hand-edited cache cannot vouch for anything. Keeping it
# would hand cmake a file it may refuse; clearing it just re-configures.
F="$TMP/f/Vendor/build/opus-iphoneos"
mkdir -p "$F"; echo "CMAKE_BUILD_TYPE:STRING=Release" > "$F/CMakeCache.txt"; touch "$F/.sentinel"
run_guard "$F"
[ ! -e "$F" ] || fail "a cache with no CMAKE_CACHEFILE_DIR was kept"
pass "removes a build directory whose cache cannot say where it belongs"

# --- 7. several directories in one call, judged one by one ------------
G1="$TMP/g/Vendor/build/flac-iphoneos"; make_build_dir "$G1" "$TMP/elsewhere/flac-iphoneos"
G2="$TMP/g/Vendor/build/flac-iphonesimulator"; make_build_dir "$G2" "$G2"
run_guard "$G1" "$G2"
[ ! -e "$G1" ] || fail "the foreign one of two directories was kept"
[ -f "$G2/.sentinel" ] || fail "the native one of two directories was discarded"
pass "judges each directory on its own cache"

# --- 8. no arguments is a caller bug, not a silent success -------------
if "$SCRIPT" > "$TMP/run.log" 2>&1; then
    fail "no arguments was accepted"
fi
grep -q "usage" "$TMP/run.log" || fail "no-argument failure did not print usage: $(cat "$TMP/run.log")"
pass "refuses to run with no build directory named"

echo "All ensure-native-cmake-cache tests passed."
