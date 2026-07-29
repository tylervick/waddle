#!/bin/bash
# Prints one content hash covering everything that determines the contents
# of Vendor/out/WoofEngine.xcframework: the vendored engine tree and the two
# scripts that build it.
#
# Three consumers share this single definition:
#   1. Scripts/build-engine.sh -- stamps the value beside the built framework
#   2. Scripts/archive.sh      -- compares stamp vs. current content (stale guard)
#   3. CI                      -- engine cache key
#
# Three properties are load-bearing (all covered by
# Scripts/test-engine-fingerprint.sh):
#
#   - PATH-INDEPENDENT. Hashes repo-relative paths, so a worktree, a fresh
#     clone, and the CI checkout directory all agree on the same content.
#     Feeding absolute paths to shasum would make the hash vary by location.
#
#   - ORDER-INDEPENDENT. `LC_ALL=C sort -z` normalizes the file list, so the
#     result never depends on filesystem enumeration order.
#
#   - WORKING-TREE BASED, not git-object based. `git rev-parse HEAD:Engine/woof`
#     would be faster and exact, but it only sees COMMITTED content -- and
#     catching "I edited engine source and forgot to rebuild" is the guard's
#     entire purpose. Uncommitted edits must change this value.
#
# Covers all of Engine/woof, not just src/, so changes to the vendored
# CMakeLists.txt or third-party/ invalidate too; the old mtime guard watched
# only src/ and was blind to those. `set -euo pipefail` makes any unreadable
# input abort rather than emit a hash over a partial file set.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
{
    find Engine/woof -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
    shasum -a 256 Scripts/build-engine.sh Scripts/build-deps.sh
} | shasum -a 256 | awk '{print $1}'
