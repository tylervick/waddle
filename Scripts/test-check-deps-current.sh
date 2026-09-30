#!/bin/bash
# Tests for Scripts/check-deps-current.sh (issue #80).
#
# Fully HERMETIC: `git`, `gh` and `curl` are stubs on a controlled PATH that
# answer from fixture files under $TMP, and the pins are read from fixture
# copies of the three scripts that own them. Nothing here reaches GitHub.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/Scripts/check-deps-current.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# On failure, the check's own output is the first thing anyone needs.
fail() { echo "FAIL: $1" >&2; [ -f "$TMP/out" ] && sed 's/^/  | /' "$TMP/out" >&2; exit 1; }
pass() { echo "ok - $1"; }

# --- stubs --------------------------------------------------------------
# Each stub answers from $STUB_FIX (set per run) and is STRICT: an argument
# shape the check is not expected to produce is a loud failure, not a pass.
mkdir -p "$TMP/bin"

# git ls-remote. `--tags --refs <url>` lists $STUB_FIX/remotes/<repo>.tags;
# `<url> refs/heads/master` prints $STUB_FIX/remotes/<repo>.master. STUB_NET=down
# fails every call (no network); STUB_FAIL_REPO=<repo> fails that repo only.
cat > "$TMP/bin/git" <<'STUB'
#!/bin/sh
[ "$1" = "ls-remote" ] || { echo "stub git: unhandled args: $*" >&2; exit 64; }
shift
tags=0; url=""; ref=""
while [ $# -gt 0 ]; do
    case "$1" in
        --tags) tags=1 ;;
        --refs|--exit-code) ;;
        https://*) url="$1" ;;
        *) ref="$1" ;;
    esac
    shift
done
repo="$(basename "$url" .git)"
if [ "${STUB_NET:-}" = down ]; then echo "fatal: unable to access '$url'" >&2; exit 128; fi
if [ "${STUB_FAIL_REPO:-}" = "$repo" ]; then echo "fatal: unable to access '$url'" >&2; exit 128; fi
if [ "$tags" = 1 ]; then
    [ -f "$STUB_FIX/remotes/$repo.tags" ] || { echo "stub git: no tags fixture for $repo" >&2; exit 64; }
    awk '{ printf "%040d\trefs/tags/%s\n", NR, $1 }' "$STUB_FIX/remotes/$repo.tags"
elif [ "$ref" = "HEAD" ]; then
    # The reachability probe: any answer means "GitHub is up".
    printf '%040d\tHEAD\n' 1
elif [ "$ref" = "refs/heads/master" ]; then
    [ -f "$STUB_FIX/remotes/$repo.master" ] || { echo "stub git: no master fixture for $repo" >&2; exit 64; }
    printf '%s\t%s\n' "$(cat "$STUB_FIX/remotes/$repo.master")" "$ref"
else
    echo "stub git: unhandled ls-remote shape: $*" >&2; exit 64
fi
STUB

# gh. `auth status` succeeds; `api repos/fabiangreffrath/woof/compare/<pin>...master
# --jq .ahead_by` prints $STUB_FIX/woof.ahead.
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/sh
case "$1 $2" in
    "auth status") exit 0 ;;
    "api repos/fabiangreffrath/woof/compare/"*)
        if [ "${STUB_GH_COMPARE:-}" = fail ]; then echo "gh: HTTP 403 rate limit" >&2; exit 1; fi
        [ -f "$STUB_FIX/woof.ahead" ] || { echo "stub gh: no ahead fixture" >&2; exit 64; }
        cat "$STUB_FIX/woof.ahead"; exit 0 ;;
esac
echo "stub gh: unhandled args: $*" >&2; exit 64
STUB

# curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/<tag>/<path>:
# prints $STUB_FIX/headers/<owner>_<repo>_<tag>_<path with / as _>, or fails
# with curl's own 404 status when there is none.
cat > "$TMP/bin/curl" <<'STUB'
#!/bin/sh
url=""
for a in "$@"; do case "$a" in https://raw.githubusercontent.com/*) url="$a" ;; esac; done
[ -n "$url" ] || { echo "stub curl: unhandled args: $*" >&2; exit 64; }
key="$(printf '%s' "${url#https://raw.githubusercontent.com/}" | tr '/' '_')"
[ -f "$STUB_FIX/headers/$key" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cat "$STUB_FIX/headers/$key"
STUB
chmod +x "$TMP/bin/git" "$TMP/bin/gh" "$TMP/bin/curl"

# --- fixture builders ---------------------------------------------------

# A checkout whose every pin is current against its remotes. Cases move one
# side or the other from here.
make_fixture() { # dir
    local d="$1"
    mkdir -p "$d/Scripts" "$d/Engine/woof/third-party/miniz" "$d/Engine/woof/third-party/spng" \
             "$d/Engine/woof/third-party/yyjson" "$d/Engine/woof/third-party/libebur128" \
             "$d/remotes" "$d/headers"
    cp "$SCRIPT" "$d/Scripts/check-deps-current.sh"
    cat > "$d/Scripts/vendor-woof.sh" <<'EOF'
#!/bin/bash
WOOF_COMMIT="798acebd52b6cc1623dde556d3e3a236a25a41d1"
EOF
    cat > "$d/Scripts/fetch-freedoom.sh" <<'EOF'
#!/bin/bash
FREEDOOM_VERSION="0.13.0"
EOF
    cat > "$d/Scripts/build-deps.sh" <<'EOF'
#!/bin/bash
SDL_TAG="release-3.4.12"
OPENAL_TAG="1.25.2"
SONIVOX_TAG="v4.0.1"
LIBOGG_TAG="v1.3.6"
LIBVORBIS_TAG="v1.3.7"
LIBSNDFILE_TAG="1.2.2"
LIBFLAC_TAG="1.5.0"
LIBOPUS_TAG="v1.6.1"
EOF
    printf '#define MZ_VERSION "11.3.1"\n' > "$d/Engine/woof/third-party/miniz/miniz.h"
    printf '#define SPNG_VERSION_MAJOR 0\n#define SPNG_VERSION_MINOR 7\n#define SPNG_VERSION_PATCH 4\n' \
        > "$d/Engine/woof/third-party/spng/spng.h"
    printf '#define YYJSON_VERSION_STRING "0.12.0"\n' > "$d/Engine/woof/third-party/yyjson/yyjson.h"
    printf '#define EBUR128_VERSION_MAJOR 1\n#define EBUR128_VERSION_MINOR 2\n#define EBUR128_VERSION_PATCH 6\n' \
        > "$d/Engine/woof/third-party/libebur128/ebur128.h"

    # Remotes, in the shapes measured on 2026-09-30: SDL's odd patch numbers
    # are snapshots, openal-soft has non-version tags, libsndfile mixes v-
    # and bare numbers, freedoom has a prerelease.
    printf 'release-3.4.10\nrelease-3.4.11\nrelease-3.4.12\n' > "$d/remotes/SDL.tags"
    printf 'openal-soft-1.21.0\nutils\n1.25.1\n1.25.2\n' > "$d/remotes/openal-soft.tags"
    printf 'v3.6.16\nv4.0.0\nv4.0.1\n' > "$d/remotes/sonivox.tags"
    printf 'v1.3.5\nv1.3.6\n' > "$d/remotes/ogg.tags"
    printf 'v1.3.6\nv1.3.7\n' > "$d/remotes/vorbis.tags"
    printf '1.4.3\n1.5.0\n' > "$d/remotes/flac.tags"
    printf 'v1.5.2\nv1.6\nv1.6.1\n' > "$d/remotes/opus.tags"
    printf 'v1.0.30\n1.2.1\n1.2.2\n' > "$d/remotes/libsndfile.tags"
    printf 'v0.12.1\nv0.13.0\nv0.14.0-alpha\n' > "$d/remotes/freedoom.tags"
    echo "798acebd52b6cc1623dde556d3e3a236a25a41d1" > "$d/remotes/woof.master"
    printf 'v113\nv114\n3.0.2\n3.1.1\n' > "$d/remotes/miniz.tags"
    printf 'v0.7.3\nv0.7.4\n' > "$d/remotes/libspng.tags"
    printf '0.11.1\n0.12.0\n' > "$d/remotes/yyjson.tags"
    printf 'v1.2.5\nv1.2.6\n' > "$d/remotes/libebur128.tags"
    echo 0 > "$d/woof.ahead"
    printf '#define MZ_VERSION "11.3.1"\n' > "$d/headers/richgel999_miniz_3.1.1_miniz.h"
    printf '#define SPNG_VERSION_MAJOR 0\n#define SPNG_VERSION_MINOR 7\n#define SPNG_VERSION_PATCH 4\n' \
        > "$d/headers/randy408_libspng_v0.7.4_spng_spng.h"
    printf '#define YYJSON_VERSION_STRING "0.12.0"\n' > "$d/headers/ibireme_yyjson_0.12.0_src_yyjson.h"
    printf '#define EBUR128_VERSION_MAJOR 1\n#define EBUR128_VERSION_MINOR 2\n#define EBUR128_VERSION_PATCH 6\n' \
        > "$d/headers/jiixyj_libebur128_v1.2.6_ebur128_ebur128.h"
}

# Runs the fixture's copy with the stubs first on PATH. Extra env goes in $2.
run_check() { # fixture [env-assignment]
    env PATH="$TMP/bin:/usr/bin:/bin" STUB_FIX="$1" ${2:-} "$1/Scripts/check-deps-current.sh" > "$TMP/out" 2>&1
}
line_for() { grep "^$1 " "$TMP/out" || true; }

# --- 1. every pin current --------------------------------------------
A="$TMP/a"; make_fixture "$A"
run_check "$A" || { cat "$TMP/out" >&2; fail "all-current run exited non-zero"; }
for pin in WOOF_COMMIT SDL_TAG OPENAL_TAG SONIVOX_TAG LIBOGG_TAG LIBVORBIS_TAG LIBFLAC_TAG LIBOPUS_TAG LIBSNDFILE_TAG FREEDOOM_VERSION; do
    echo "$(line_for "$pin")" | grep -q ": current" || fail "$pin not reported current: $(line_for "$pin")"
done
for lib in miniz spng yyjson libebur128; do
    echo "$(line_for "third-party/$lib")" | grep -q ": current" || fail "third-party/$lib not reported current: $(line_for "third-party/$lib")"
done
grep -q "0 behind, 0 undetermined" "$TMP/out" || fail "summary missing or wrong: $(tail -1 "$TMP/out")"
pass "reports every pin current when it matches upstream"

# --- 2. pins behind, with the shapes that trip a naive newest-tag --------
B="$TMP/b"; make_fixture "$B"
# release-3.4.13 is a version-bump commit, not a release (odd patch).
printf 'release-3.4.13\nrelease-3.4.14\nrelease-3.4.16\n' >> "$B/remotes/SDL.tags"
echo "1.25.3" >> "$B/remotes/openal-soft.tags"
echo "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b" > "$B/remotes/woof.master"
echo 37 > "$B/woof.ahead"
# Opus publishes v1.6 with two components and it is a release, not a tag
# shape to skip (CodeRabbit on PR #289).
echo "v1.7" >> "$B/remotes/opus.tags"
echo "3.1.2" >> "$B/remotes/miniz.tags"
printf '#define MZ_VERSION "11.3.2"\n' > "$B/headers/richgel999_miniz_3.1.2_miniz.h"
run_check "$B" || { cat "$TMP/out" >&2; fail "behind run exited non-zero (staleness must report, not gate)"; }
echo "$(line_for SDL_TAG)" | grep -q "behind 2 releases (newest release-3.4.16)" \
    || fail "SDL distance wrong (odd patch counted, or wrong newest): $(line_for SDL_TAG)"
echo "$(line_for OPENAL_TAG)" | grep -q "behind 1 release (newest 1.25.3)" \
    || fail "openal distance wrong: $(line_for OPENAL_TAG)"
echo "$(line_for WOOF_COMMIT)" | grep -q "behind master by 37 commits" \
    || fail "woof distance wrong: $(line_for WOOF_COMMIT)"
echo "$(line_for third-party/miniz)" | grep -q "behind (newest tag 3.1.2 declares 11.3.2)" \
    || fail "miniz not compared through its header: $(line_for third-party/miniz)"
echo "$(line_for FREEDOOM_VERSION)" | grep -q ": current" \
    || fail "a prerelease tag counted as a release: $(line_for FREEDOOM_VERSION)"
echo "$(line_for LIBOPUS_TAG)" | grep -q "behind 1 release (newest v1.7)" \
    || fail "a two-component opus release was not counted: $(line_for LIBOPUS_TAG)"
grep -q "5 behind, 0 undetermined" "$TMP/out" || fail "summary wrong: $(tail -1 "$TMP/out")"
pass "reports how far behind, skipping snapshots and prereleases"

# --- 3. the case this check exists to get right: a failed query --------
# A `git ls-remote` that fails must read "could not determine", never
# "current" or "0 behind"; a wrong zero is the answer that makes everyone
# stop looking (docs/learnings/masked-exit-status-fails-open.md).
C="$TMP/c"; make_fixture "$C"
if run_check "$C" "STUB_FAIL_REPO=openal-soft"; then
    fail "a failed query exited zero"
fi
echo "$(line_for OPENAL_TAG)" | grep -q "could not determine" \
    || fail "failed query not reported as undetermined: $(line_for OPENAL_TAG)"
! echo "$(line_for OPENAL_TAG)" | grep -q "current\|behind" \
    || fail "failed query reported a distance: $(line_for OPENAL_TAG)"
echo "$(line_for SDL_TAG)" | grep -q ": current" || fail "one failed query hid the other pins: $(line_for SDL_TAG)"
grep -q "1 undetermined" "$TMP/out" || fail "summary did not count the undetermined pin: $(tail -1 "$TMP/out")"
pass "reports a failed query as undetermined, exits non-zero, keeps the rest"

# --- 4. no network and no gh: a clean skip --------------------------------
D="$TMP/d"; make_fixture "$D"
mkdir -p "$TMP/nogh"; ln -sf "$TMP/bin/git" "$TMP/nogh/git"; ln -sf "$TMP/bin/curl" "$TMP/nogh/curl"
if ! env PATH="$TMP/nogh:/usr/bin:/bin" STUB_FIX="$D" STUB_NET=down "$D/Scripts/check-deps-current.sh" > "$TMP/out" 2>&1; then
    cat "$TMP/out" >&2; fail "offline run exited non-zero instead of skipping"
fi
grep -q "^skip - " "$TMP/out" || fail "offline run did not print a skip line: $(cat "$TMP/out")"
! grep -q "could not determine" "$TMP/out" || fail "offline run reported pins as undetermined instead of skipping"
pass "skips cleanly with no network and no gh"

# --- 5. a pin the check is told to watch but cannot find -----------------
# Fail closed: a checker that reports the other pins green while one goes
# unwatched is the artefact that makes everyone stop looking.
E="$TMP/e"; make_fixture "$E"
sed -i.bak '/^SONIVOX_TAG=/d' "$E/Scripts/build-deps.sh"; rm -f "$E/Scripts/build-deps.sh.bak"
if run_check "$E"; then
    fail "a missing pin exited zero"
fi
grep -q "error:.*SONIVOX_TAG" "$TMP/out" || fail "missing pin not named in an error: $(cat "$TMP/out")"
pass "fails closed on a pin missing from the file that owns it"

# --- 6. network but no gh: the woof distance degrades, nothing skips -------
F="$TMP/f"; make_fixture "$F"
echo "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b" > "$F/remotes/woof.master"
env PATH="$TMP/nogh:/usr/bin:/bin" STUB_FIX="$F" "$F/Scripts/check-deps-current.sh" > "$TMP/out" 2>&1 \
    || { cat "$TMP/out" >&2; fail "no-gh run exited non-zero"; }
echo "$(line_for WOOF_COMMIT)" | grep -q "behind master" || fail "woof not reported behind without gh: $(line_for WOOF_COMMIT)"
! echo "$(line_for WOOF_COMMIT)" | grep -q "by [0-9]* commits" || fail "a commit count was invented without gh: $(line_for WOOF_COMMIT)"
echo "$(line_for SDL_TAG)" | grep -q ": current" || fail "tags were not checked without gh: $(line_for SDL_TAG)"
pass "checks tags without gh and reports woof behind master without a count"

# --- 6b. gh present, but the compare query fails --------------------------
# Different from "no gh": here the count was asked for and not answered, so
# the honest line is "could not determine", not a distance without a count
# that exits 0 (CodeRabbit on PR #289).
F2="$TMP/f2"; make_fixture "$F2"
echo "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b" > "$F2/remotes/woof.master"
if run_check "$F2" "STUB_GH_COMPARE=fail"; then
    fail "a failed gh compare exited zero"
fi
echo "$(line_for WOOF_COMMIT)" | grep -q "could not determine" \
    || fail "a failed gh compare was not reported as undetermined: $(line_for WOOF_COMMIT)"
pass "reports a failed gh compare as undetermined rather than a distance without a count"

# --- 7. a third-party header that cannot be fetched --------------------
G="$TMP/g"; make_fixture "$G"
rm "$G/headers/ibireme_yyjson_0.12.0_src_yyjson.h"
if run_check "$G"; then
    fail "an unfetchable header exited zero"
fi
echo "$(line_for third-party/yyjson)" | grep -q "could not determine" \
    || fail "unfetchable header not reported as undetermined: $(line_for third-party/yyjson)"
pass "reports a third-party library whose upstream header cannot be read as undetermined"

# --- 8. a pin that is not among upstream's tags at all -------------------
# A renamed or deleted tag: no distance can be measured from it.
H="$TMP/h"; make_fixture "$H"
sed -i.bak 's/^SDL_TAG=.*/SDL_TAG="release-3.9.98"/' "$H/Scripts/build-deps.sh"; rm -f "$H/Scripts/build-deps.sh.bak"
if run_check "$H"; then
    fail "a pin absent upstream exited zero"
fi
echo "$(line_for SDL_TAG)" | grep -q "could not determine" \
    || fail "pin absent upstream not reported as undetermined: $(line_for SDL_TAG)"
pass "reports a pin that upstream no longer has as undetermined"

echo "All check-deps-current tests passed."
