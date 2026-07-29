#!/bin/bash
# Refuses to proceed when Vendor/out/WoofEngine.xcframework does not match
# the sources that should have produced it. Exits 0 and prints nothing when
# the framework is current; exits 1 with rebuild guidance otherwise.
#
# The heavy engine build (SDL/OpenAL + Woof) is deliberately NOT part of
# archiving, but a framework that does not match its sources silently ships
# stale bits -- that is how a missing SDL_CAMERA=OFF (ITMS-90683) or an
# unbuilt engine fix reaches App Review. Fail loudly instead; rebuilding is a
# separate, explicit step.
#
# Compares CONTENT, not mtimes. The previous `find -newer` guard fired
# whenever sources merely had newer timestamps than the framework -- which is
# what a fresh worktree checkout or a restored CI cache always produces, even
# when the bytes are identical -- and demanded a ~25-minute rebuild that
# changed nothing. Content comparison also widens coverage from
# Engine/woof/src to all of Engine/woof, so edits to the vendored
# CMakeLists.txt or third-party/ now count; they were invisible before.
#
# Fails CLOSED: an unreadable source tree, a failure to compute the
# fingerprint, or a missing stamp all refuse, rather than letting bits of
# unknown provenance through.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FW="$ROOT/Vendor/out/WoofEngine.xcframework"
STAMP="$FW.fingerprint"

if [ ! -d "$FW" ]; then
  echo "error: $FW is missing." >&2
  echo "       build the engine first: mise run bootstrap" >&2
  echo "       (or: Scripts/build-deps.sh && Scripts/build-engine.sh)" >&2
  exit 1
fi
if ! CURRENT_FP="$("$ROOT/Scripts/engine-fingerprint.sh")"; then
  echo "error: could not fingerprint the engine sources (a source or build" >&2
  echo "       script is missing or unreadable) — refusing to continue." >&2
  exit 1
fi
if [ ! -f "$STAMP" ]; then
  echo "error: $STAMP is missing — the framework predates this guard, or was" >&2
  echo "       assembled by hand." >&2
  echo "       rebuild before archiving: Scripts/build-deps.sh && Scripts/build-engine.sh" >&2
  exit 1
fi
if [ "$CURRENT_FP" != "$(cat "$STAMP")" ]; then
  echo "error: engine sources/scripts changed since WoofEngine.xcframework was built." >&2
  echo "       rebuild before archiving: Scripts/build-deps.sh && Scripts/build-engine.sh" >&2
  echo "       (build-deps.sh is only needed when SDL/OpenAL config changed)" >&2
  exit 1
fi
