#!/bin/bash
# Clears a CMake build directory whose cache belongs to another checkout,
# so the configure that follows starts clean instead of failing (issue #72).
#
# Vendor/build/*/CMakeCache.txt records the absolute path it was written in
# (CMAKE_CACHEFILE_DIR). A worktree that inherits a copy of Vendor/build from
# another checkout -- Orca seeds one after its setup hook has already run, and
# a plain `git worktree add` copies nothing but gets one by hand -- hands
# cmake a cache naming the other checkout, and cmake refuses to configure.
# Loop runs 2026-08-08 and 2026-08-11 each lost minutes to that, after the
# setup-time `rm -rf Vendor/build` had run and lost its race. This runs at
# the point of use, from build-deps.sh and build-engine.sh, right before each
# `cmake -S ... -B <dir>`, where ordering cannot defeat it.
#
# For each directory named: no CMakeCache.txt, or one whose recorded
# directory IS this directory, leaves it alone -- a valid cache must not be
# discarded, since re-configuring on every build costs far more than the one
# stale cache did. A cache naming some other directory, or naming none, is
# removed with the directory, and one line says so. Paths are compared
# physically: a worktree that symlinks Vendor at the primary checkout shares
# the primary's build directories, whose caches name the primary's real path.
#
# Exit 0 when every directory is native or was cleared; non-zero only for a
# caller error (no arguments) or a removal that failed.
set -euo pipefail

if [ $# -eq 0 ]; then
    echo "usage: $0 <build-dir>..." >&2
    exit 2
fi

for dir in "$@"; do
    cache="$dir/CMakeCache.txt"
    if [ ! -f "$cache" ]; then
        continue
    fi

    # Read the status before interpreting the output: a missing line and a
    # failed read must both end in "clear", never in "keep".
    recorded=""
    if line="$(grep '^CMAKE_CACHEFILE_DIR:INTERNAL=' "$cache")"; then
        recorded="${line#CMAKE_CACHEFILE_DIR:INTERNAL=}"
    fi

    reason=""
    if [ -z "$recorded" ]; then
        reason="its CMakeCache.txt does not say where it was written"
    else
        here="$(cd "$dir" && pwd -P)"
        if [ -d "$recorded" ]; then
            there="$(cd "$recorded" && pwd -P)"
        else
            there="$recorded"
        fi
        if [ "$here" != "$there" ]; then
            reason="its CMakeCache.txt was written in $recorded"
        fi
    fi

    if [ -n "$reason" ]; then
        echo "$(basename "$dir"): clearing a foreign CMake cache -- $reason (see Scripts/ensure-native-cmake-cache.sh)"
        rm -rf "$dir"
    fi
done
