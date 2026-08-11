#!/bin/bash
# Rejects App/AppIcon.icon/icon.json configurations that build green and do the
# wrong thing. Exits 0 and prints nothing when the package is sound; exits 1
# naming the problem otherwise.
#
# Every rule here exists because actool does NOT complain. A malformed or
# ineffective icon.json compiles without error or warning, and the only symptom
# is an icon that silently renders wrong -- which nobody notices until it is on
# a device, or on the App Store. See docs/learnings/icon-composer-package.md.
#
# Fails CLOSED: unparseable JSON, a missing package, or an unreadable Assets/
# directory all refuse rather than passing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="${1:-$ROOT/App/AppIcon.icon}"

[ -d "$PACKAGE" ] || { echo "error: $PACKAGE is missing." >&2; exit 1; }
[ -f "$PACKAGE/icon.json" ] || { echo "error: $PACKAGE/icon.json is missing." >&2; exit 1; }
[ -d "$PACKAGE/Assets" ] || { echo "error: $PACKAGE/Assets is missing." >&2; exit 1; }

PACKAGE="$PACKAGE" python3 - <<'PY' || exit 1
import json, os, sys
from pathlib import Path

pkg = Path(os.environ["PACKAGE"])
problems = []

try:
    icon = json.loads((pkg / "icon.json").read_text())
except json.JSONDecodeError as exc:
    sys.exit(f"error: {pkg.name}/icon.json is not valid JSON: {exc}")
if not isinstance(icon, dict):
    sys.exit(f"error: {pkg.name}/icon.json must be a JSON object")

# 1. Root-level fill-specializations is accepted by actool and then discarded.
#    It is the obvious way to give the icon a dark background, it compiles
#    clean, and it does nothing -- proven by the compiled renditions being
#    byte-identical in size with and without it. Only a LAYER honours the key.
if "fill-specializations" in icon:
    problems.append(
        "root-level 'fill-specializations' is silently ignored by actool.\n"
        "       It compiles without error and has no effect on the output.\n"
        "       Per-appearance fills are only honoured on a layer; a different\n"
        "       background per appearance must be authored in Icon Composer.app."
    )

# 2. A layer pointing at artwork that is not there also builds green -- the
#    layer just renders empty.
declared = set()
for g_i, group in enumerate(icon.get("groups", [])):
    for l_i, layer in enumerate(group.get("layers", [])):
        name = layer.get("image-name")
        if not name:
            problems.append(f"groups[{g_i}].layers[{l_i}] has no 'image-name'.")
            continue
        declared.add(name)
        if not (pkg / "Assets" / name).is_file():
            problems.append(f"layer '{name}' has no matching file in Assets/.")

if not declared:
    problems.append("icon.json declares no layers, so the icon renders empty.")

# 3. An orphan means someone hand-edited the package: render-icons.sh only ever
#    writes the referenced artwork, so anything else is a leftover from a rename
#    and will confuse the next person to open it.
for asset in sorted(p.name for p in (pkg / "Assets").iterdir() if p.is_file()):
    if asset not in declared:
        problems.append(f"Assets/{asset} is not referenced by any layer.")

if problems:
    for p in problems:
        print(f"error: {p}", file=sys.stderr)
    print("       regenerate: mise run icons", file=sys.stderr)
    sys.exit(1)
PY
