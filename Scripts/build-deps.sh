#!/bin/bash
# Builds SDL3 and OpenAL Soft as static libs for iOS device + simulator.
set -euo pipefail
SDL_TAG="release-3.4.12"
OPENAL_TAG="1.25.2"
SONIVOX_TAG="v4.0.1"
# Streamed music (#196). libsndfile needs Ogg and Vorbis as EXTERNAL libraries
# for OGG support -- it vendors neither -- so this is three pins, not one.
# Build order below is load-bearing: vorbis needs ogg, sndfile needs both.
LIBOGG_TAG="v1.3.6"
LIBVORBIS_TAG="v1.3.7"
LIBSNDFILE_TAG="1.2.2"
# libsndfile treats its external codecs as a SET: HAVE_EXTERNAL_XIPH_LIBS is
# one flag gating Ogg, Vorbis, FLAC and Opus together, with no per-codec
# option. Wanting OGG therefore costs FLAC and Opus too -- configure fails at
# target_link_libraries without them. All four are BSD-3-Clause; libsndfile
# itself is LGPL-2.1, conveyed under the GPL exactly as OpenAL Soft already is.
LIBFLAC_TAG="1.5.0"
LIBOPUS_TAG="v1.6.1"
IOS_DEPLOYMENT_TARGET="26.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Vendor/src"
OUT="$ROOT/Vendor/out"
mkdir -p "$SRC"

# A checkout may be reused only when it is the ROOT of a real work tree whose
# HEAD is the commit tagged $2. A bare repo, an interrupted clone, a stray
# directory, and a checkout left at some other tag all read as false, so each
# gets replaced rather than silently built.
#
# Compare COMMITS, not `git describe --exact-match`: several tags can point at
# one commit, and describe would then report a name other than the one asked
# for. The requested tag is usually absent outright from a clone made at the
# previous pin (`--depth 1 --branch` fetches only that one tag), which is the
# ordinary bumped-pin case and is handled by the same rev-parse failing.
at_pin() { # dir tag
    local dir="$1" tag="$2" top head want
    [ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || return 1
    # --is-inside-work-tree is not sufficient on its own: Vendor/src lives
    # inside this repo's own work tree, so a plain `mkdir Vendor/src/SDL`
    # answers "true" and then reports Waddle's HEAD. Require the work tree's
    # root to be $dir itself. `pwd -P` matches the physical path git prints.
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ "$top" = "$(cd "$dir" && pwd -P)" ] || return 1
    head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || return 1
    want="$(git -C "$dir" rev-parse --verify --quiet "refs/tags/$tag^{commit}")" || return 1
    [ "$head" = "$want" ]
}

# Guarding the clone on directory existence alone let a bumped SDL_TAG or
# OPENAL_TAG rebuild the OLD sources on any machine that had built once --
# no error, no warning, and a framework that did not match the pin.
fetch() { # dir url tag
    local dir="$SRC/$1"
    if [ -e "$dir" ] && ! at_pin "$dir" "$3"; then
        echo "$1: checkout is not at $3 -- replacing it"
        rm -rf "$dir"
    fi
    if [ ! -d "$dir" ]; then
        git clone --depth 1 --branch "$3" "$2" "$dir"
    fi
}
fetch SDL https://github.com/libsdl-org/SDL.git "$SDL_TAG"
fetch openal-soft https://github.com/kcat/openal-soft.git "$OPENAL_TAG"
fetch sonivox https://github.com/pedrolcl/sonivox.git "$SONIVOX_TAG"
fetch ogg https://github.com/xiph/ogg.git "$LIBOGG_TAG"
fetch vorbis https://github.com/xiph/vorbis.git "$LIBVORBIS_TAG"
fetch flac https://github.com/xiph/flac.git "$LIBFLAC_TAG"
fetch opus https://github.com/xiph/opus.git "$LIBOPUS_TAG"
fetch libsndfile https://github.com/libsndfile/libsndfile.git "$LIBSNDFILE_TAG"

build() { # srcdir platform extra-cmake-args...
    local src="$1" platform="$2"
    shift 2
    local bdir="$ROOT/Vendor/build/$(basename "$src")-$platform"
    cmake -S "$src" -B "$bdir" -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$platform" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$OUT/$platform" \
        -DCMAKE_PREFIX_PATH="$OUT/$platform" \
        -DCMAKE_FIND_ROOT_PATH="$OUT/$platform" \
        "$@"
    cmake --build "$bdir"
    cmake --install "$bdir"
}

for platform in iphoneos iphonesimulator; do
    # SDL_TEST_LIBRARY (the SDL3_test helper lib) defaults ON independently
    # of SDL_TESTS; nothing here links it, so don't build or install it.
    # SDL_CAMERA=OFF: Waddle has no camera feature, but SDL's camera subsystem
    # links AVCaptureDevice, which makes App Store validation demand an
    # NSCameraUsageDescription purpose string (ITMS-90683). Disabling it drops
    # the API reference entirely so no unused-camera permission is declared.
    build "$SRC/SDL" "$platform" \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
        -DSDL_TEST_LIBRARY=OFF -DSDL_CAMERA=OFF
    # Pre-seed the check_cxx_compiler_flag() cache variable that OpenAL Soft's
    # CMakeLists.txt (~line 276/409) uses to gate -Werror=function-effects.
    # Xcode 26.2's clang has a false positive in alc/backends/coreaudio.cpp
    # (lines 646, 824): "attribute 'nonblocking' should not be added via type
    # conversion" under -Wfunction-effects, which OpenAL Soft 1.25.2 promotes
    # to -Werror for Clang 17+. check_cxx_compiler_flag() only runs its probe
    # if the result variable isn't already defined, so seeding it to OFF here
    # skips the probe and disables both the warning and the -Werror escalation
    # without touching the vendored source.
    build "$SRC/openal-soft" "$platform" \
        -DLIBTYPE=STATIC -DALSOFT_REQUIRE_COREAUDIO=ON \
        -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_EMBED_HRTF_DATA=ON \
        -DHAVE_WFUNCTION_EFFECTS=OFF
    # SONiVOX EAS: the wavetable synth the predecessor per-game apps used, so
    # its instruments are the ones long-time players know every track by (#116,
    # docs/superpowers/specs/2026-08-17-midi-wavetable-design.md).
    #
    # USE_44KHZ=OFF and USE_16BITS_SAMPLES=OFF are the two options that decide
    # what a player hears: together they select the 22 kHz 8-bit bank the
    # predecessor shipped. Scripts/check-eas-bank.sh refuses a pin bump that
    # changes either those options or the instrument bank itself.
    #
    # NEW_HOST_WRAPPER=ON is load-bearing, not a preference: it supplies the
    # EAS_FILE {handle, readAt, size} reader, which is how the engine hands EAS
    # a music lump straight out of a WAD with no file on disk. Without it the
    # music module cannot be written at all.
    #
    # SF2 and ZLIB off keep this dependency from pulling in anything else --
    # with both off it needs no external library, not even -lm on Apple.
    # Streamed music (#196), in dependency order: vorbis needs ogg, and
    # libsndfile needs all four. CMAKE_POLICY_VERSION_MINIMUM=3.5 is required
    # for vorbis and libsndfile: both declare a cmake_minimum_required below
    # 3.5, which CMake 4 (pinned at 4.4.2 in mise.toml) refuses outright.
    build "$SRC/ogg" "$platform" \
        -DBUILD_SHARED_LIBS=OFF -DINSTALL_DOCS=OFF
    build "$SRC/vorbis" "$platform" \
        -DBUILD_SHARED_LIBS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    build "$SRC/flac" "$platform" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_CXXLIBS=OFF -DBUILD_PROGRAMS=OFF \
        -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DBUILD_DOCS=OFF \
        -DINSTALL_MANPAGES=OFF -DWITH_OGG=ON
    build "$SRC/opus" "$platform" \
        -DBUILD_SHARED_LIBS=OFF -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF
    build "$SRC/libsndfile" "$platform" \
        -DBUILD_SHARED_LIBS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
        -DENABLE_MPEG=OFF -DENABLE_CPACK=OFF
    # A libsndfile without the Xiph codecs still builds, installs and links --
    # it just cannot decode the one format this dependency exists for. Today a
    # missing codec fails configure outright (measured), so this is belt and
    # braces rather than a live hole; it is here because the failure it guards
    # is silent by nature, and the whole point of #196 was a silent one.
    sndcfg="$ROOT/Vendor/build/libsndfile-$platform/src/config.h"
    if ! grep -q '^#define HAVE_EXTERNAL_XIPH_LIBS 1' "$sndcfg"; then
        echo "error: libsndfile for $platform was configured without the Xiph" >&2
        echo "       codecs -- it cannot decode Ogg, which is why it is here." >&2
        echo "       check that ogg/vorbis/flac/opus installed to $OUT/$platform" >&2
        exit 1
    fi
    build "$SRC/sonivox" "$platform" \
        -DBUILD_SHARED_LIBS=OFF \
        -DUSE_44KHZ=OFF -DUSE_16BITS_SAMPLES=OFF \
        -DNEW_HOST_WRAPPER=ON \
        -DSF2_SUPPORT=OFF -DZLIB_SUPPORT=OFF \
        -DEAS_WT_SYNTH=ON -DEAS_FM_SYNTH=OFF \
        -DBUILD_TESTING=OFF -DBUILD_APPLICATION=OFF
done
echo "Deps installed under $OUT/{iphoneos,iphonesimulator}"
