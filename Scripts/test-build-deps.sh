#!/bin/bash
# Tests for the fetch() pin guard in Scripts/build-deps.sh.
#
# Fully HERMETIC: builds throwaway upstream repos in a temp dir, copies the
# real build-deps.sh beside them, and stubs cmake. Nothing here touches the
# real Vendor/ tree and nothing reaches the network.
#
# Two fixture rewrites are needed to get there, and each is checked to have
# actually applied -- a silently no-op sed would send the test at the real
# github.com URLs and turn a hermetic unit test into a slow, flaky network one:
#
#   - the two hardcoded clone URLs are repointed at local file:// repos.
#     file:// (not a bare path) matters: --depth is ignored for plain local
#     paths, so only the URL form exercises the real shallow-clone code path.
#   - SDL_TAG is rewritten in place between runs, with the same
#     `sed 's/^SDL_TAG=.*/...'` a developer bumping the pin would make. The
#     tags are plain assignments, not ${SDL_TAG:-...}, so an exported variable
#     is overwritten by line 4 and never reaches fetch(); editing the
#     assignment is the only way to actually move the pin.
#
# cmake is stubbed because fetch()'s behaviour is the whole subject here and
# the real thing would build SDL twice per case. fetch() runs before any
# build, so a no-op cmake leaves the part under test fully exercised.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# Upstream repos never inherit the caller's identity or signing config. Both
# opt-outs are load-bearing on a machine that signs by default: commit.gpgsign
# would hand every fixture commit to a signer that cannot sign here, and
# tag.gpgSign turns `git tag v1` into an annotated tag, which then dies on the
# missing message with the distinctly unhelpful "fatal: no tag message?".
git_c() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c tag.gpgSign=false "$@"; }

# One upstream repo with two tags, so "the pin moved" is expressible.
make_upstream() { # dest
    mkdir -p "$1"
    git_c -C "$1" init -q
    echo one > "$1/VERSION"; git_c -C "$1" add VERSION
    git_c -C "$1" commit -qm one; git_c -C "$1" tag v1
    echo two > "$1/VERSION"; git_c -C "$1" add VERSION
    git_c -C "$1" commit -qm two; git_c -C "$1" tag v2
}

# A fixture repo: the real script, pointed at local upstreams, with a stub cmake.
make_fixture() { # dest
    mkdir -p "$1/Scripts" "$1/bin"
    cp "$ROOT/Scripts/build-deps.sh" "$1/Scripts/build-deps.sh"
    sed -i.bak \
        -e "s|https://github.com/libsdl-org/SDL.git|file://$TMP/up-sdl|" \
        -e "s|https://github.com/kcat/openal-soft.git|file://$TMP/up-openal|" \
        "$1/Scripts/build-deps.sh"
    rm -f "$1/Scripts/build-deps.sh.bak"
    grep -q "file://$TMP/up-sdl" "$1/Scripts/build-deps.sh" \
        || fail "fixture setup: SDL clone URL no longer matches; this test would hit the network"
    grep -q "file://$TMP/up-openal" "$1/Scripts/build-deps.sh" \
        || fail "fixture setup: openal-soft clone URL no longer matches; this test would hit the network"
    printf '#!/bin/bash\nexit 0\n' > "$1/bin/cmake"
    chmod +x "$1/bin/cmake"
    set_tag "$1" SDL_TAG v1
    set_tag "$1" OPENAL_TAG v1
}

set_tag() { # fixture var tag -- the pin edit a developer would make by hand
    sed -i.bak "s/^$2=.*/$2=\"$3\"/" "$1/Scripts/build-deps.sh"
    rm -f "$1/Scripts/build-deps.sh.bak"
    grep -q "^$2=\"$3\"$" "$1/Scripts/build-deps.sh" \
        || fail "fixture setup: could not rewrite $2; the assignment's shape must have changed"
}

deps()   { PATH="$1/bin:$PATH" "$1/Scripts/build-deps.sh"; }
at_tag() { git -C "$1/Vendor/src/$2" describe --tags --exact-match 2>/dev/null; }

make_upstream "$TMP/up-sdl"
make_upstream "$TMP/up-openal"

# 1. Nothing on disk yet -> clones both deps at the pinned tag.
make_fixture "$TMP/a"
deps "$TMP/a" >"$TMP/out" 2>&1 || fail "first run failed: $(cat "$TMP/out")"
[ "$(at_tag "$TMP/a" SDL)" = v1 ] || fail "first run did not check out the pinned tag"
[ "$(at_tag "$TMP/a" openal-soft)" = v1 ] || fail "first run left openal-soft off its pin"
pass "clones each dep at its pinned tag when nothing exists yet"

# 2. THE REGRESSION. A checkout already exists at the old pin; the pin is then
#    bumped. The old guard skipped on directory existence alone, so the build
#    silently used v1 source while claiming v2 -- the bug this test exists for.
set_tag "$TMP/a" SDL_TAG v2
deps "$TMP/a" >"$TMP/out" 2>&1 || fail "run after pin bump failed: $(cat "$TMP/out")"
[ "$(at_tag "$TMP/a" SDL)" = v2 ] \
    || fail "bumped SDL_TAG left the old checkout in place (got $(at_tag "$TMP/a" SDL))"
[ "$(cat "$TMP/a/Vendor/src/SDL/VERSION")" = two ] \
    || fail "checkout reports v2 but its content is still the old tag's"
pass "re-fetches when the pin is bumped under an existing checkout"

# 3. The bump must not drag unrelated deps along: openal-soft is still on its
#    own pin, so it should be left exactly as it was, not re-cloned.
touch "$TMP/a/Vendor/src/openal-soft/.untouched"
deps "$TMP/a" >"$TMP/out" 2>&1 || fail "no-op run failed: $(cat "$TMP/out")"
[ -f "$TMP/a/Vendor/src/openal-soft/.untouched" ] \
    || fail "re-cloned a dep that was already at its pin"
[ "$(at_tag "$TMP/a" SDL)" = v2 ] || fail "no-op run moved SDL off its pin"
pass "leaves a checkout alone when it already matches the pin"

# 4. Rolling a pin BACKWARD is the same operation forward -- worth pinning down
#    because a "fetch newer" style fix would pass case 2 and fail here.
set_tag "$TMP/a" SDL_TAG v1
deps "$TMP/a" >"$TMP/out" 2>&1 || fail "run after pin rollback failed: $(cat "$TMP/out")"
[ "$(at_tag "$TMP/a" SDL)" = v1 ] || fail "rolling the pin back left the newer checkout in place"
pass "re-fetches when the pin moves backward too"

# 5. A directory that is not a git checkout at all -- an interrupted clone, or
#    a hand-made dir -- must be replaced, not built. The old guard accepted it.
make_fixture "$TMP/b"
mkdir -p "$TMP/b/Vendor/src/SDL"; echo junk > "$TMP/b/Vendor/src/SDL/stray"
deps "$TMP/b" >"$TMP/out" 2>&1 || fail "run over a non-git dir failed: $(cat "$TMP/out")"
[ "$(at_tag "$TMP/b" SDL)" = v1 ] || fail "did not replace a directory that was not a checkout"
[ ! -f "$TMP/b/Vendor/src/SDL/stray" ] || fail "kept debris from the replaced directory"
pass "replaces a directory that is not a valid checkout"

echo "All build-deps tests passed."
