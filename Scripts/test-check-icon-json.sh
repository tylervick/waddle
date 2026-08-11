#!/bin/bash
# Tests for Scripts/check-icon-json.sh.
#
# Fully HERMETIC: builds fake .icon packages in a temp dir and points the guard
# at them. Nothing here touches App/AppIcon.icon.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# A sound package: one group, one layer, artwork present and referenced.
make_pkg() { # dest [icon.json body]
    rm -rf "$1"; mkdir -p "$1/Assets"
    printf 'png-bytes' > "$1/Assets/mark.png"
    cat > "$1/icon.json" <<'JSON'
{ "fill": { "automatic-gradient": "extended-gray:1.00000,1.00000" },
  "groups": [ { "layers": [ { "image-name": "mark.png", "name": "Mark" } ] } ],
  "supported-platforms": { "squares": "shared" } }
JSON
}
check() { "$ROOT/Scripts/check-icon-json.sh" "$1"; }

# 1. Sound package -> pass silently.
make_pkg "$TMP/ok"
check "$TMP/ok" > "$TMP/out" 2>&1 || fail "rejected a sound package: $(cat "$TMP/out")"
[ -s "$TMP/out" ] && fail "printed output on the success path"
pass "passes silently on a sound package"

# 2. THE point of this guard: root-level fill-specializations compiles green in
#    actool and does nothing, so only a check like this can catch it.
make_pkg "$TMP/rootfill"
python3 - "$TMP/rootfill/icon.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["fill-specializations"] = [{"appearance": "dark",
                              "value": {"automatic-gradient": "extended-gray:0.1,1.0"}}]
json.dump(d, open(p, "w"), indent=2)
PY
if check "$TMP/rootfill" > "$TMP/out" 2>&1; then fail "accepted root-level fill-specializations"; fi
grep -q "silently ignored" "$TMP/out" || fail "refusal does not explain that the key is a no-op"
pass "rejects root-level fill-specializations"

# 3. The SAME key on a layer is legitimate and must still pass -- the shipping
#    Icon Composer example uses it there.
make_pkg "$TMP/layerfill"
python3 - "$TMP/layerfill/icon.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["groups"][0]["layers"][0]["fill-specializations"] = [
    {"appearance": "dark", "value": {"automatic-gradient": "extended-gray:0.1,1.0"}}]
json.dump(d, open(p, "w"), indent=2)
PY
check "$TMP/layerfill" > "$TMP/out" 2>&1 || fail "rejected layer-level fill-specializations: $(cat "$TMP/out")"
pass "allows layer-level fill-specializations"

# 4. Layer pointing at artwork that is not there -> builds green, renders empty.
make_pkg "$TMP/missing"; rm "$TMP/missing/Assets/mark.png"
if check "$TMP/missing" > "$TMP/out" 2>&1; then fail "accepted a layer with no artwork"; fi
grep -q "no matching file" "$TMP/out" || fail "missing-artwork error is unclear"
pass "rejects a layer whose artwork is absent"

# 5. Orphaned asset -> someone hand-edited the package.
make_pkg "$TMP/orphan"; printf 'stale' > "$TMP/orphan/Assets/old-mark.png"
if check "$TMP/orphan" > "$TMP/out" 2>&1; then fail "accepted an unreferenced asset"; fi
grep -q "not referenced" "$TMP/out" || fail "orphan error is unclear"
pass "rejects unreferenced artwork left in Assets/"

# 6. No layers at all -> the icon renders empty.
make_pkg "$TMP/nolayers"; rm "$TMP/nolayers/Assets/mark.png"
printf '{"groups":[]}' > "$TMP/nolayers/icon.json"
if check "$TMP/nolayers" > "$TMP/out" 2>&1; then fail "accepted a package with no layers"; fi
grep -q "no layers" "$TMP/out" || fail "empty-icon error is unclear"
pass "rejects a package that declares no layers"

# 7. Fails closed on malformed or absent input rather than assuming it is fine.
make_pkg "$TMP/bad"; printf '{not json' > "$TMP/bad/icon.json"
if check "$TMP/bad" > "$TMP/out" 2>&1; then fail "accepted unparseable icon.json"; fi
grep -q "not valid JSON" "$TMP/out" || fail "malformed JSON error is unclear"

make_pkg "$TMP/nojson"; rm "$TMP/nojson/icon.json"
if check "$TMP/nojson" > "$TMP/out" 2>&1; then fail "accepted a package with no icon.json"; fi

if check "$TMP/does-not-exist" > "$TMP/out" 2>&1; then fail "accepted a missing package"; fi
pass "fails closed on malformed, incomplete, or absent packages"

echo "all check-icon-json tests passed"
