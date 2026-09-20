#!/usr/bin/env python3
"""Turn the engine's GLOBALDIFF lines into variable names.

The engine (WoofIOS_DebugGlobalsCheckpoint, Engine/woof/src/woof_ios.c) runs
once per session when WADDLE_DEBUG_GLOBALS_DIFF is set: at the start of the
game loop it snapshots the writable data sections of the image it lives in,
and from the second session on prints one line per byte range that changed
since the previous checkpoint:

    GLOBALDIFF-IMAGE <image path> slide=0x<n>
    GLOBALDIFF <segment>,<section> unslid=0x<addr> len=<n> old=<hex> new=<hex>

Those lines are engine stdout, so they land in the app's session log
(Diagnostics/session-*.log in the app container) and in the xcresult's
captured stdout. This script maps each range to the variable that contains
it, using the image's DWARF: Release-built engine objects carry no symbol for
an initialised `static` (clang -O3 privatises them), so `nm` cannot name
MainDef, but with -g in the engine build the DWARF can, once dsymutil has
relocated it against the linked image.

Two sessions of the SAME game make every listed engine variable a candidate
for state that leaks between sessions (issue #253's family). Game A then game
B lists what depends on the previous game. Expect noise: tic counters, RNG,
heap pointers. The point is a finite list to read, not a verdict.

Usage (after a WaddleUITests/GlobalsDiffProbeTests run in the simulator):

    Scripts/globals-diff.py --container <simulator udid>
    Scripts/globals-diff.py --log path/to/session-....log [--image Waddle.debug.dylib]
    Scripts/globals-diff.py --log ... --dwarf-text dwarfdump-output.txt   # tests

Only engine variables (declared under Engine/woof/) are shown unless --all.
"""
import argparse
import bisect
import glob
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_IMAGE = os.path.join(
    ROOT, "App/build/Build/Products/Debug-iphonesimulator/Waddle.app/Waddle.debug.dylib")
BUNDLE_ID = "com.tylervick.waddle"

DIFF_RE = re.compile(
    r"^GLOBALDIFF (\S+) unslid=0x([0-9a-fA-F]+) len=(\d+) old=([0-9a-fA-F]*) new=([0-9a-fA-F]*)")
IMAGE_RE = re.compile(r"^GLOBALDIFF-IMAGE (\S+) slide=0x([0-9a-fA-F]+)")


def parse_log(text):
    ranges, image = [], None
    for line in text.splitlines():
        m = IMAGE_RE.match(line)
        if m:
            image = m.group(1)
            continue
        m = DIFF_RE.match(line)
        if m:
            ranges.append({"section": m.group(1), "addr": int(m.group(2), 16),
                           "len": int(m.group(3)), "old": m.group(4), "new": m.group(5)})
    return image, ranges


def parse_dwarf(text):
    """DW_TAG_variable entries with a DW_OP_addr location -> sorted list."""
    variables = []
    current = None
    for line in text.splitlines():
        if "DW_TAG_" in line:
            if current and "addr" in current and "name" in current:
                variables.append(current)
            current = {} if "DW_TAG_variable" in line else None
            continue
        if current is None:
            continue
        m = re.search(r'DW_AT_name\s*\("([^"]*)"\)', line)
        if m:
            current["name"] = m.group(1)
        m = re.search(r'DW_AT_decl_file\s*\("([^"]*)"\)', line)
        if m:
            current["file"] = m.group(1)
        m = re.search(r"DW_AT_decl_line\s*\((\d+)\)", line)
        if m:
            current["line"] = int(m.group(1))
        # A privatised static comes out of dsymutil as its section base plus
        # an offset: "DW_OP_addr 0x874a30, DW_OP_plus_uconst 0x58". The offset
        # is part of the address.
        m = re.search(r"DW_AT_location\s*\(DW_OP_addr 0x([0-9a-fA-F]+)"
                      r"(?:, DW_OP_plus_uconst 0x([0-9a-fA-F]+))?\)", line)
        if m:
            current["addr"] = int(m.group(1), 16) + (int(m.group(2), 16) if m.group(2) else 0)
    if current and "addr" in current and "name" in current:
        variables.append(current)
    variables.sort(key=lambda v: v["addr"])
    return variables


NM_RE = re.compile(r"^([0-9a-fA-F]+) ([dDbBsS]) (\S+)$")


def parse_nm(text):
    """Data symbols from `nm -n` -> entries with no file/line (nm knows none)."""
    symbols = []
    for line in text.splitlines():
        m = NM_RE.match(line.strip())
        if m:
            name = m.group(3)
            symbols.append({"name": name[1:] if name.startswith("_") else name,
                            "addr": int(m.group(1), 16), "source": "nm"})
    return symbols


def nm_for_image(image):
    return subprocess.run(["nm", "-n", image], check=True, capture_output=True, text=True).stdout


def merge_symbols(dwarf_vars, nm_syms):
    """One sorted list; where both know an address, DWARF wins (it has file:line)."""
    known = {v["addr"] for v in dwarf_vars}
    merged = list(dwarf_vars) + [s for s in nm_syms if s["addr"] not in known]
    merged.sort(key=lambda v: v["addr"])
    return merged


def dwarf_for_image(image):
    if not os.path.exists(image):
        sys.exit(f"error: image not found: {image} (build the app first, or pass --image)")
    with tempfile.TemporaryDirectory() as tmp:
        dsym = os.path.join(tmp, "image.dSYM")
        subprocess.run(["dsymutil", image, "-o", dsym], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        out = subprocess.run(["dwarfdump", "--debug-info", dsym], check=True,
                             capture_output=True, text=True).stdout
    return out


def newest_session_log(udid):
    container = subprocess.run(
        ["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"],
        check=True, capture_output=True, text=True).stdout.strip()
    logs = glob.glob(os.path.join(container, "**", "session-*.log"), recursive=True)
    if not logs:
        sys.exit(f"error: no session-*.log under {container}")
    return max(logs, key=os.path.getmtime)


def is_engine(var):
    return "Engine/woof/" in var.get("file", "")


def display_path(path):
    """A DWARF decl_file is absolute on the machine that built the image, which
    need not be this one (CI builds it under /Users/runner/...), so a path
    relative to this checkout can come out as ../../../../builder/... Print
    from the repository's Engine/ or App/ marker instead."""
    for marker in ("/Engine/", "/App/", "/Scripts/"):
        i = path.find(marker)
        if i >= 0:
            return path[i + 1:]
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--log", help="a session log or captured stdout holding GLOBALDIFF lines")
    src.add_argument("--container", metavar="UDID",
                     help="read the newest session log from this simulator's app container")
    ap.add_argument("--image", default=DEFAULT_IMAGE,
                    help="the linked image the engine ran in (default: the Debug simulator dylib)")
    ap.add_argument("--dwarf-text", help="use this dwarfdump --debug-info output instead of dsymutil+dwarfdump")
    ap.add_argument("--nm-text", help="use this `nm -n` output instead of running nm on the image")
    ap.add_argument("--all", action="store_true", help="show variables outside Engine/woof too")
    args = ap.parse_args()

    log_path = newest_session_log(args.container) if args.container else args.log
    with open(log_path, errors="replace") as f:
        image_in_log, ranges = parse_log(f.read())
    if not ranges:
        sys.exit(f"error: no GLOBALDIFF lines in {log_path}: was WADDLE_DEBUG_GLOBALS_DIFF set, "
                 "and did a second session reach its checkpoint?")

    if args.dwarf_text:
        with open(args.dwarf_text, errors="replace") as f:
            variables = parse_dwarf(f.read())
    else:
        variables = parse_dwarf(dwarf_for_image(args.image))
    if not variables:
        sys.exit("error: no DW_TAG_variable entries with addresses; is the engine built with -g?")
    # nm fills in what DWARF does not cover (SDL, OpenAL, Swift, and any
    # engine global compiled without -g), so a DWARF variable far behind a
    # changed range cannot claim it just for being the nearest thing named.
    if args.nm_text:
        with open(args.nm_text, errors="replace") as f:
            nm_syms = parse_nm(f.read())
    elif args.dwarf_text:
        nm_syms = []
    else:
        nm_syms = parse_nm(nm_for_image(args.image))
    variables = merge_symbols(variables, nm_syms)
    addrs = [v["addr"] for v in variables]

    hits = {}
    outside = 0
    for r in ranges:
        i = bisect.bisect_right(addrs, r["addr"]) - 1
        var = variables[i] if i >= 0 else None
        if var is None or (not args.all and not is_engine(var)):
            outside += 1
            continue
        # Keyed on the variable, not its name: file-scope statics in different
        # objects share names (`ret`, `msg`, `buffer`), and each is its own
        # address and source location.
        hits.setdefault(var["addr"], (var, []))[1].append(r)

    print(f"# {log_path}")
    print(f"# image: {image_in_log or args.image}")
    for _, (var, rs) in sorted(hits.items(), key=lambda kv: kv[1][0]["addr"]):
        name = var["name"]
        where = (f"{display_path(var['file'])}:{var.get('line', '?')}" if var.get("file")
                 else "nm symbol, no source location")
        for r in rs:
            off = r["addr"] - var["addr"]
            print(f"{name}+0x{off:x} len={r['len']} {r['old']} -> {r['new']}  ({where}) [{r['section']}]")
    scope = "" if args.all else " engine"
    print(f"# {sum(len(rs) for _, rs in hits.values())} range(s) in {len(hits)}{scope} variable(s); "
          f"{outside} range(s) outside{' the engine (use --all)' if not args.all else ' any known variable'}")


if __name__ == "__main__":
    main()
