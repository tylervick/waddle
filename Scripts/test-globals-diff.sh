#!/bin/bash
# Hermetic tests for Scripts/globals-diff.py: the GLOBALDIFF-line parser and
# the nearest-preceding-variable lookup, fed a canned dwarfdump listing so no
# dsymutil, dwarfdump or built app is needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/Scripts/fixtures/globals-diff"
fail=0
check() { # name, expected-substring, actual
    if printf '%s' "$3" | grep -qF -- "$2"; then echo "ok - $1"; else echo "FAIL - $1: expected '$2' in:"; printf '%s\n' "$3"; fail=1; fi
}
refute() {
    if printf '%s' "$3" | grep -qF -- "$2"; then echo "FAIL - $1: did not expect '$2' in:"; printf '%s\n' "$3"; fail=1; else echo "ok - $1"; fi
}

out="$(python3 "$ROOT/Scripts/globals-diff.py" --log "$FIX/session.log" --dwarf-text "$FIX/dwarf.txt")"
check "offset inside MainDef resolves to MainDef with its file:line" "MainDef+0x4" "$out"
check "MainDef carries decl location" "mn_menu.c:335" "$out"
check "old and new bytes are reported" "05000000 -> 04000000" "$out"
check "second range resolves to EpiDef" "EpiDef+0x4" "$out"
refute "non-engine variable is filtered out by default" "swiftThing" "$out"
check "ranges outside engine variables are counted, not dropped" "2 range(s) outside" "$out"

out_all="$(python3 "$ROOT/Scripts/globals-diff.py" --log "$FIX/session.log" --dwarf-text "$FIX/dwarf.txt" --all)"
check "--all shows non-engine variables" "swiftThing+0x8" "$out_all"

# Ranges past the last DWARF variable belong to whatever nm knows about at
# that address (SDL, OpenAL, Swift): a DWARF variable far behind them must not
# claim them, and --all must name the nm symbol instead.
out_nm="$(python3 "$ROOT/Scripts/globals-diff.py" --log "$FIX/session-nm.log" --dwarf-text "$FIX/dwarf.txt" --nm-text "$FIX/nm.txt" --all)"
check "DWARF variable still wins when it is the nearest" "MainDef+0x4" "$out_nm"
check "nm symbol wins when it is nearer than any DWARF variable" "SDL_something+0x10" "$out_nm"
check "nm bss symbol resolves too" "alcNoise+0x14" "$out_nm"
refute "a far-behind DWARF variable does not claim an nm-owned range" "swiftThing+0x810" "$out_nm"
out_nm_engine="$(python3 "$ROOT/Scripts/globals-diff.py" --log "$FIX/session-nm.log" --dwarf-text "$FIX/dwarf.txt" --nm-text "$FIX/nm.txt")"
refute "nm-only symbols are outside the engine filter by default" "SDL_something" "$out_nm_engine"

# dsymutil places an initialised static that clang privatised as a section
# base plus an offset (DW_OP_addr X, DW_OP_plus_uconst Y). The offset is part
# of the address; dropping it hands every such variable's bytes to whichever
# variable sits at the bare base. Measured: MainDef.numitems reported as
# EpiMenuEpi+0x58 before this case existed.
out_bo="$(python3 "$ROOT/Scripts/globals-diff.py" --log "$FIX/session-base-offset.log" --dwarf-text "$FIX/dwarf.txt")"
check "a base+offset location resolves to the offset variable" "NewDef+0x0" "$out_bo"
refute "the bare-base variable does not claim the range" "EpiMenuEpi+0x58" "$out_bo"

# A log with no GLOBALDIFF lines is a failure, not an empty success: the seam
# was not armed, or the session never reached its checkpoint.
if python3 "$ROOT/Scripts/globals-diff.py" --log /dev/null --dwarf-text "$FIX/dwarf.txt" >/dev/null 2>&1; then
    echo "FAIL - empty log must exit non-zero"; fail=1
else
    echo "ok - empty log exits non-zero"
fi

[ "$fail" -eq 0 ] && echo "test-globals-diff: all passed"
exit "$fail"
