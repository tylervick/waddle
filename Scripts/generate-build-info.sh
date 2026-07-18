#!/bin/bash
# Writes App/Sources/Generated/BuildInfo.generated.swift with the current
# commit/branch/build time, so a build shown on a test device's debug HUD
# can be traced back to an exact source state.
#
# Run twice in the normal lifecycle, both required:
#   1. Standalone, once, BEFORE the first `xcodegen generate`. XcodeGen's
#      default `sources: [path: Sources]` scan is a static file list
#      snapshotted at generate time (not a live folder reference), and
#      App/Sources/Generated/ is gitignored (its content is
#      machine/build-specific), so a fresh checkout has no file there at
#      all until this runs once -- without it, xcodegen would never add
#      BuildInfo.generated.swift to the project, and it would silently
#      stay missing even after later builds create it.
#   2. Automatically, on every build after that, via project.yml's
#      preBuildScripts phase on the BoomBox target (declared with this
#      file as its output, so Xcode sequences it before compilation) --
#      this is what keeps commit/branch/builtAt fresh per build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/App/Sources/Generated"
OUT_FILE="$OUT_DIR/BuildInfo.generated.swift"
mkdir -p "$OUT_DIR"

if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    commit="$(git -C "$ROOT" rev-parse --short HEAD)"
    if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
        commit="${commit}+"
    fi
    branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
else
    commit="unknown"
    branch="unknown"
fi
built_at="$(date -u '+%Y-%m-%d %H:%M')"

new_content="enum BuildInfo {
    static let commit = \"$commit\"
    static let branch = \"$branch\"
    static let builtAt = \"$built_at\"
}
"

# Only write (touch mtime) if content actually changed. builtAt has
# minute-granularity, so two builds in the same minute with no git changes
# would otherwise dirty this file -- and every incremental-build target
# that imports it -- for no reason.
if [ ! -f "$OUT_FILE" ] || [ "$(cat "$OUT_FILE")" != "$new_content" ]; then
    printf '%s' "$new_content" > "$OUT_FILE"
fi
