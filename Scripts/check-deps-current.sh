#!/bin/bash
# Reports how far each vendored native dependency pin is behind upstream, so
# drift surfaces without anyone measuring by hand (issue #80). Renovate
# ignores every one of these (renovate.json's own description says so), and
# the only reason #79 knew the pins had drifted is that someone went and
# looked. This reports; it does not gate: a pin a month behind is not a
# reason to turn a pull request red.
#
# What it reads, and from where:
#   WOOF_COMMIT          Scripts/vendor-woof.sh      vs fabiangreffrath/woof master
#   SDL_TAG              Scripts/build-deps.sh       vs libsdl-org/SDL release-3.* (even
#                                                    patch numbers only: odd ones are
#                                                    version-bump commits, not releases)
#   OPENAL_TAG, SONIVOX_TAG, LIBOGG_TAG, LIBVORBIS_TAG, LIBFLAC_TAG, LIBOPUS_TAG,
#   LIBSNDFILE_TAG       Scripts/build-deps.sh       vs each upstream's release tags
#   FREEDOOM_VERSION     Scripts/fetch-freedoom.sh   vs freedoom/freedoom release tags
#                                                    (prereleases such as -alpha excluded)
#   third-party/{miniz,spng,yyjson,libebur128}      the libraries vendored inside
#                        Engine/woof/third-party/    Woof itself, which move only when
#                                                    WOOF_COMMIT moves. Compared through
#                                                    the version macro in the same header
#                                                    fetched at upstream's newest tag,
#                                                    because miniz's MZ_VERSION does not
#                                                    map onto its tag names (3.0.2 declares
#                                                    11.0.2, 3.1.1 declares 11.3.1).
#
# Three outcomes, kept distinct on purpose:
#   skip   - `git` cannot reach GitHub at all (no network): prints `skip - ...`,
#            exits 0. Working offline is not blocked.
#   error  - a pin this script is told to watch is missing from the file that
#            owns it: `error: ...`, exit 1. A checker that reports the other
#            pins green while one goes unwatched is the artefact that makes
#            everyone stop looking, so it fails closed.
#   report - one line per pin: `current`, `behind N ...`, or
#            `could not determine -- <reason>` when that one query failed or
#            the pin is not among upstream's tags. A failed query is never
#            reported as "0 behind" (docs/learnings/masked-exit-status-fails-open.md);
#            any undetermined pin makes the exit status 1 so a scheduled run
#            notices, while stale pins alone exit 0.
#
# `gh` is optional: with it, WOOF_COMMIT's distance is a commit count from the
# compare API; without it, the line says "behind master" and stops there.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

behind=0
undetermined=0
checked=0

# --- reading pins: fail closed on a missing one ---------------------------
read_pin() { # var file
    local line
    if ! line="$(grep "^$1=" "$ROOT/$2")"; then
        echo "error: $1 is not defined in $2 -- a pin this check is told to watch must be there" >&2
        exit 1
    fi
    line="${line#*=}"
    line="${line%\"}"
    echo "${line#\"}"
}

# --- reachability: skip cleanly when there is no network ------------------
if ! command -v git >/dev/null 2>&1; then
    echo "skip - git not installed; dependency pins not checked"
    exit 0
fi
if ! git ls-remote --exit-code https://github.com/libsdl-org/SDL.git HEAD >/dev/null 2>&1; then
    echo "skip - GitHub unreachable (git ls-remote failed); dependency pins not checked"
    exit 0
fi
have_gh=0
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    have_gh=1
fi

report() { # line
    echo "$1"
    checked=$((checked + 1))
    case "$1" in
        *": behind"*) behind=$((behind + 1)) ;;
        *": could not determine"*) undetermined=$((undetermined + 1)) ;;
    esac
}

# Tags of a repo that look like releases, one per line, newest last.
# Ordering strips a leading "v" or "release-" so a repo that changed its
# spelling over time (libsndfile: v1.0.30 then 1.2.2) still sorts right.
# Reads the status before the output: a failed ls-remote returns non-zero
# and prints nothing, and the caller must not read "nothing" as "no tags".
release_tags() { # url filter-regex
    local raw
    raw="$(git ls-remote --tags --refs "$1" 2>/dev/null)" || return 1
    printf '%s\n' "$raw" | sed 's|.*refs/tags/||' | grep -E "$2" \
        | awk '{ v=$0; sub(/^(v|release-)/, "", v); print v "\t" $0 }' \
        | sort -t "$(printf '\t')" -k1,1V | cut -f2
    return 0
}

# One tagged pin. Distance is the number of release tags newer than the pin.
check_tag_pin() { # name pin repo filter-regex
    local name="$1" pin="$2" url="https://github.com/$3.git" tags newer newest n
    if ! tags="$(release_tags "$url" "$4")"; then
        report "$name $pin: could not determine -- git ls-remote failed for $3"
        return
    fi
    if ! printf '%s\n' "$tags" | grep -qx -- "$pin"; then
        report "$name $pin: could not determine -- $pin is not among $3's release tags"
        return
    fi
    newer="$(printf '%s\n' "$tags" | sed -n "/^$(printf '%s' "$pin" | sed 's/[.[\*^$]/\\&/g')\$/,\$p" | tail -n +2)"
    if [ -z "$newer" ]; then
        report "$name $pin: current"
        return
    fi
    n="$(printf '%s\n' "$newer" | wc -l | tr -d ' ')"
    newest="$(printf '%s\n' "$newer" | tail -1)"
    if [ "$n" = 1 ]; then
        report "$name $pin: behind 1 release (newest $newest)"
    else
        report "$name $pin: behind $n releases (newest $newest)"
    fi
}

# --- WOOF_COMMIT against master -------------------------------------------
woof_pin="$(read_pin WOOF_COMMIT Scripts/vendor-woof.sh)"
if master="$(git ls-remote https://github.com/fabiangreffrath/woof.git refs/heads/master 2>/dev/null)" \
   && [ -n "$master" ]; then
    master_sha="${master%%	*}"
    if [ "$master_sha" = "$woof_pin" ]; then
        report "WOOF_COMMIT ${woof_pin:0:8}: current"
    elif [ "$have_gh" = 1 ] \
         && ahead="$(gh api "repos/fabiangreffrath/woof/compare/$woof_pin...master" --jq .ahead_by 2>/dev/null)" \
         && [ -n "$ahead" ]; then
        report "WOOF_COMMIT ${woof_pin:0:8}: behind master by $ahead commits (master ${master_sha:0:8})"
    else
        report "WOOF_COMMIT ${woof_pin:0:8}: behind master (master ${master_sha:0:8}; count needs gh)"
    fi
else
    report "WOOF_COMMIT ${woof_pin:0:8}: could not determine -- git ls-remote failed for fabiangreffrath/woof"
fi

# --- tagged pins --------------------------------------------------------
NUMERIC='^[0-9]+\.[0-9]+\.[0-9]+$'
V_NUMERIC='^v[0-9]+\.[0-9]+\.[0-9]+$'
ANY_NUMERIC='^v?[0-9]+\.[0-9]+\.[0-9]+$'
check_tag_pin SDL_TAG "$(read_pin SDL_TAG Scripts/build-deps.sh)" libsdl-org/SDL '^release-3\.[0-9]+\.[0-9]*[02468]$'
check_tag_pin OPENAL_TAG "$(read_pin OPENAL_TAG Scripts/build-deps.sh)" kcat/openal-soft "$NUMERIC"
check_tag_pin SONIVOX_TAG "$(read_pin SONIVOX_TAG Scripts/build-deps.sh)" pedrolcl/sonivox "$V_NUMERIC"
check_tag_pin LIBOGG_TAG "$(read_pin LIBOGG_TAG Scripts/build-deps.sh)" xiph/ogg "$V_NUMERIC"
check_tag_pin LIBVORBIS_TAG "$(read_pin LIBVORBIS_TAG Scripts/build-deps.sh)" xiph/vorbis "$V_NUMERIC"
check_tag_pin LIBFLAC_TAG "$(read_pin LIBFLAC_TAG Scripts/build-deps.sh)" xiph/flac "$NUMERIC"
check_tag_pin LIBOPUS_TAG "$(read_pin LIBOPUS_TAG Scripts/build-deps.sh)" xiph/opus "$V_NUMERIC"
check_tag_pin LIBSNDFILE_TAG "$(read_pin LIBSNDFILE_TAG Scripts/build-deps.sh)" libsndfile/libsndfile "$ANY_NUMERIC"
# fetch-freedoom.sh downloads from releases/download/v${FREEDOOM_VERSION}, so
# the tag is the pin with a v in front.
check_tag_pin FREEDOOM_VERSION "v$(read_pin FREEDOOM_VERSION Scripts/fetch-freedoom.sh)" freedoom/freedoom "$V_NUMERIC"

# --- the libraries vendored inside Woof ----------------------------------
# The version as `header` declares it: either one string macro, or a
# MAJOR/MINOR/PATCH triple joined with dots. Reads the status first: a
# missing macro is "unknown", never an empty string compared as equal.
header_version() { # file macro-prefix kind
    local file="$1" m="$2" a b c
    case "$3" in
        string)
            grep -m1 "^#define $m \"" "$file" | sed 's/.*"\(.*\)".*/\1/' | grep . || return 1 ;;
        triple)
            a="$(grep -m1 "^#define ${m}_MAJOR " "$file" | awk '{print $3}')" || return 1
            b="$(grep -m1 "^#define ${m}_MINOR " "$file" | awk '{print $3}')" || return 1
            c="$(grep -m1 "^#define ${m}_PATCH " "$file" | awk '{print $3}')" || return 1
            [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] || return 1
            echo "$a.$b.$c" ;;
    esac
}

check_third_party() { # name vendored-header repo upstream-header macro kind filter-regex
    local name="$1" local_hdr="$ROOT/Engine/woof/third-party/$2" repo="$3" up_hdr="$4" macro="$5" kind="$6" filter="$7"
    local ours tags newest theirs
    if ! ours="$(header_version "$local_hdr" "$macro" "$kind")"; then
        report "third-party/$name: could not determine -- $macro not found in $2"
        return
    fi
    if ! tags="$(release_tags "https://github.com/$repo.git" "$filter")" || [ -z "$tags" ]; then
        report "third-party/$name $ours: could not determine -- git ls-remote failed for $repo"
        return
    fi
    newest="$(printf '%s\n' "$tags" | tail -1)"
    if ! theirs_file="$(mktemp)" \
       || ! curl -fsSL "https://raw.githubusercontent.com/$repo/$newest/$up_hdr" > "$theirs_file" 2>/dev/null \
       || ! theirs="$(header_version "$theirs_file" "$macro" "$kind")"; then
        rm -f "${theirs_file:-}"
        report "third-party/$name $ours: could not determine -- could not read $up_hdr at $repo $newest"
        return
    fi
    rm -f "$theirs_file"
    if [ "$ours" = "$theirs" ]; then
        report "third-party/$name $ours: current (tag $newest)"
    else
        report "third-party/$name $ours: behind (newest tag $newest declares $theirs)"
    fi
}
check_third_party miniz miniz/miniz.h richgel999/miniz miniz.h MZ_VERSION string "$NUMERIC"
check_third_party spng spng/spng.h randy408/libspng spng/spng.h SPNG_VERSION triple "$V_NUMERIC"
check_third_party yyjson yyjson/yyjson.h ibireme/yyjson src/yyjson.h YYJSON_VERSION_STRING string "$NUMERIC"
check_third_party libebur128 libebur128/ebur128.h jiixyj/libebur128 ebur128/ebur128.h EBUR128_VERSION triple "$V_NUMERIC"

echo "deps-current: $checked checked, $behind behind, $undetermined undetermined"
[ "$undetermined" -eq 0 ]
