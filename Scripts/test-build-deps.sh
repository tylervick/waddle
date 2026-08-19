#!/bin/bash
# Tests for Scripts/build-deps.sh's dependency-checkout guard (issue #13).
#
# Fully HERMETIC: no network, no real compiler. Throwaway upstream repos are
# built locally and the fixture's clone URLs are repointed at them, so every
# `git clone` the script runs is a file:// clone of a repo this test just made.
# Both rewrites assert they applied, so renaming a URL upstream turns this into
# a loud failure instead of a quiet network test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/Scripts/build-deps.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# The fixture repos must not inherit the developer's git config.
# commit.gpgsign is the obvious half; tag.gpgSign is the one that bites, since
# it makes a plain `git tag v1` annotated and dies with "no tag message?" --
# an error naming neither signing nor config. See
# docs/learnings/git-fixtures-inherit-signing-config.md.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# --- fixture builders -------------------------------------------------

# Two commits, tagged v1 and v2, so a pin can be moved in either direction.
make_upstream() { # dir
    git init -q -b main "$1"
    echo one > "$1/f"; git -C "$1" add f; git -C "$1" commit -qm one; git -C "$1" tag v1
    echo two > "$1/f"; git -C "$1" add f; git -C "$1" commit -qm two; git -C "$1" tag v2
}
make_upstream "$TMP/upstream-sdl"
make_upstream "$TMP/upstream-openal"
make_upstream "$TMP/upstream-sonivox"
for dep in ogg vorbis flac opus libsndfile; do
    make_upstream "$TMP/upstream-$dep"
done

# A copy of the REAL script with its two clone URLs repointed at those repos.
# file:// (not a bare path) is required: a local-path clone ignores --depth.
make_fixture() { # dest
    mkdir -p "$1/Scripts" "$1/bin"
    sed -e "s|https://github.com/libsdl-org/SDL.git|file://$TMP/upstream-sdl|" \
        -e "s|https://github.com/kcat/openal-soft.git|file://$TMP/upstream-openal|" \
        -e "s|https://github.com/pedrolcl/sonivox.git|file://$TMP/upstream-sonivox|" \
        -e "s|https://github.com/xiph/ogg.git|file://$TMP/upstream-ogg|" \
        -e "s|https://github.com/xiph/vorbis.git|file://$TMP/upstream-vorbis|" \
        -e "s|https://github.com/xiph/flac.git|file://$TMP/upstream-flac|" \
        -e "s|https://github.com/xiph/opus.git|file://$TMP/upstream-opus|" \
        -e "s|https://github.com/libsndfile/libsndfile.git|file://$TMP/upstream-libsndfile|" \
        "$SCRIPT" > "$1/Scripts/build-deps.sh"
    chmod +x "$1/Scripts/build-deps.sh"
    grep -q "file://$TMP/upstream-sdl" "$1/Scripts/build-deps.sh" \
        || fail "fixture did not repoint the SDL clone URL -- this test would hit the network"
    grep -q "file://$TMP/upstream-openal" "$1/Scripts/build-deps.sh" \
        || fail "fixture did not repoint the openal-soft clone URL -- this test would hit the network"
    grep -q "file://$TMP/upstream-sonivox" "$1/Scripts/build-deps.sh" \
        || fail "fixture did not repoint the sonivox clone URL -- this test would hit the network"
    for dep in ogg vorbis flac opus libsndfile; do
        grep -q "file://$TMP/upstream-$dep" "$1/Scripts/build-deps.sh" \
            || fail "fixture did not repoint the $dep clone URL -- this test would hit the network"
    done
    # The checkout guard is under test, not the build. Stub cmake out entirely.
    printf '#!/bin/sh\nexit 0\n' > "$1/bin/cmake"
    chmod +x "$1/bin/cmake"
}

# Rewrites the pin the way a developer bumping it would: in the file itself.
set_pin() { # fixture var tag
    sed -i.bak "s|^$2=.*|$2=\"$3\"|" "$1/Scripts/build-deps.sh"
    rm -f "$1/Scripts/build-deps.sh.bak"
    grep -qx "$2=\"$3\"" "$1/Scripts/build-deps.sh" \
        || fail "fixture pin rewrite for $2=$3 did not apply"
}

run_deps() { # fixture
    PATH="$1/bin:$PATH" "$1/Scripts/build-deps.sh" > "$TMP/run.log" 2>&1 \
        || { cat "$TMP/run.log" >&2; fail "build-deps.sh exited non-zero"; }
}

# Asserts $1 is a real work tree rooted at itself, checked out at $3 of $2.
assert_at() { # dir upstream tag msg
    local got want top
    [ "$(git -C "$1" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] \
        || fail "$4: not a work tree"
    top="$(git -C "$1" rev-parse --show-toplevel)"
    [ "$top" = "$(cd "$1" && pwd -P)" ] || fail "$4: work tree root is $top, not the checkout dir"
    [ -f "$1/f" ] || fail "$4: sources are missing"
    got="$(git -C "$1" rev-parse HEAD)"
    want="$(git -C "$2" rev-parse "$3^{commit}")"
    [ "$got" = "$want" ] || fail "$4: at $got, wanted $3 ($want)"
}

# --- 1. cold clone ----------------------------------------------------
A="$TMP/a"; make_fixture "$A"
set_pin "$A" SDL_TAG v1; set_pin "$A" OPENAL_TAG v1; set_pin "$A" SONIVOX_TAG v1
for v in LIBOGG_TAG LIBVORBIS_TAG LIBFLAC_TAG LIBOPUS_TAG LIBSNDFILE_TAG; do set_pin "$A" "$v" v1; done
run_deps "$A"
assert_at "$A/Vendor/src/SDL" "$TMP/upstream-sdl" v1 "cold clone of SDL"
assert_at "$A/Vendor/src/openal-soft" "$TMP/upstream-openal" v1 "cold clone of openal-soft"
assert_at "$A/Vendor/src/sonivox" "$TMP/upstream-sonivox" v1 "cold clone of sonivox"
# The codec stack (#196). Five pins, because libsndfile gates Ogg, Vorbis,
# FLAC and Opus behind one build flag and refuses to configure without all of
# them -- so a checkout silently left behind on any one of them breaks the
# build of the library that needs it, not just its own.
for dep in ogg vorbis flac opus libsndfile; do
    assert_at "$A/Vendor/src/$dep" "$TMP/upstream-$dep" v1 "cold clone of $dep"
done
pass "clones each dep at its pinned tag when nothing exists yet"

# --- 2. the bug in #13: a bumped pin under an existing checkout --------
set_pin "$A" SDL_TAG v2
run_deps "$A"
assert_at "$A/Vendor/src/SDL" "$TMP/upstream-sdl" v2 "bumped SDL_TAG left the old checkout"
assert_at "$A/Vendor/src/openal-soft" "$TMP/upstream-openal" v1 "untouched pin re-fetched anyway"
assert_at "$A/Vendor/src/sonivox" "$TMP/upstream-sonivox" v1 "untouched pin re-fetched anyway"
pass "re-fetches when the pin is bumped under an existing checkout"

# --- 3. a matching checkout is reused, not re-cloned -------------------
# A sentinel that only survives if the directory was left alone -- asserting
# the tag alone would pass even if the guard re-cloned on every single run.
touch "$A/Vendor/src/SDL/.sentinel"
run_deps "$A"
[ -f "$A/Vendor/src/SDL/.sentinel" ] || fail "re-cloned a checkout that already matched the pin"
pass "leaves a checkout alone when it already matches the pin"

# --- 4. a pin that moves backward ------------------------------------
# A "fetch something newer" shaped fix would pass case 2 and fail here.
set_pin "$A" SDL_TAG v1
run_deps "$A"
assert_at "$A/Vendor/src/SDL" "$TMP/upstream-sdl" v1 "rolled-back SDL_TAG did not re-fetch"
pass "re-fetches when the pin moves backward too"

# --- 5. a directory that is not a checkout at all ---------------------
# An interrupted clone leaves exactly this behind.
rm -rf "$A/Vendor/src/SDL/.git"
run_deps "$A"
assert_at "$A/Vendor/src/SDL" "$TMP/upstream-sdl" v1 "did not replace a non-checkout directory"
pass "replaces a directory that is not a valid checkout"

# --- 6. a BARE repo at the checkout path ------------------------------
# A bare clone has both HEAD and refs/tags/<pin>, so a commit-only comparison
# accepts it -- while there are no sources on disk to build at all.
rm -rf "$A/Vendor/src/SDL"
git clone -q --bare "file://$TMP/upstream-sdl" "$A/Vendor/src/SDL"
[ "$(git -C "$A/Vendor/src/SDL" rev-parse HEAD)" \
  = "$(git -C "$TMP/upstream-sdl" rev-parse 'v2^{commit}')" ] \
  || fail "fixture bug: the bare clone was expected to sit at v2"
set_pin "$A" SDL_TAG v2
run_deps "$A"
assert_at "$A/Vendor/src/SDL" "$TMP/upstream-sdl" v2 "did not replace a bare repo"
pass "replaces a bare repo whose HEAD happens to match the pin"

# --- 7. an empty directory inside an ENCLOSING repo -------------------
# The real Vendor/src lives inside Waddle's own work tree, so `mkdir
# Vendor/src/SDL` answers --is-inside-work-tree=true and reports the ENCLOSING
# repo's HEAD and tags. With a same-named tag there, a check that omits the
# work-tree-root test reuses an empty directory and builds nothing.
B="$TMP/b"; make_fixture "$B"
git init -q -b main "$B"
echo enclosing > "$B/README"; git -C "$B" add README; git -C "$B" commit -qm enclosing
git -C "$B" tag v1
set_pin "$B" SDL_TAG v1; set_pin "$B" OPENAL_TAG v1; set_pin "$B" SONIVOX_TAG v1
for v in LIBOGG_TAG LIBVORBIS_TAG LIBFLAC_TAG LIBOPUS_TAG LIBSNDFILE_TAG; do set_pin "$B" "$v" v1; done
mkdir -p "$B/Vendor/src/SDL"
run_deps "$B"
assert_at "$B/Vendor/src/SDL" "$TMP/upstream-sdl" v1 "reused an empty dir inside the enclosing repo"
pass "replaces an empty directory nested inside an enclosing repo"

echo "all build-deps checkout-guard tests passed"
