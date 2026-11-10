#!/usr/bin/env python3
"""Summarise an Instruments Time Profiler trace of an engine session.

Issue #246's companion to Scripts/profile-session.sh: that script records the
traces, this one turns one into the numbers a baseline is made of, so the
docs/learnings/ entry can be regenerated instead of re-derived. Given a
.trace from profile-session.sh (or a time-profile table already exported
with `xctrace export`), it prints CPU per thread and per core type, the main
thread charged exclusively to engine phases (tic, BSP walk, column/span
loops, HUD, present, event pump), the hottest symbols, and what the busiest
worker threads are doing.

    Scripts/profile-summary.py build/profile-session/run-1.trace
    Scripts/profile-summary.py some/run-1.time-profile.xml

Attribution is by symbol name, so a Release build with symbols (the one
profile-session.sh makes) is assumed; an unsymbolicated trace shows up as
"other". The phase table is Woof!'s: extend PHASES when the engine grows a
new hot path, and say so in the learning that cites the numbers.
"""
import os, subprocess, sys, tempfile

if len(sys.argv) != 2:
    sys.exit("usage: Scripts/profile-summary.py <run.trace | time-profile.xml>")
_src = sys.argv[1]
if _src.endswith(".trace"):
    _tmp = tempfile.NamedTemporaryFile(suffix=".time-profile.xml", delete=False)
    _tmp.close()
    subprocess.run(["xcrun", "xctrace", "export", "--input", _src,
                    "--xpath", '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]',
                    "--output", _tmp.name], check=True, capture_output=True)
    sys.argv[1] = _tmp.name
import sys, re, collections
import xml.etree.ElementTree as ET

path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()
byid = {}

def resolve(el):
    """Return the element that carries data for el (follows ref=)."""
    if el is None:
        return None
    r = el.get("ref")
    if r is not None:
        return byid[r]
    i = el.get("id")
    if i is not None:
        byid[i] = el
    return el

def frames_of(bt):
    bt = resolve(bt)
    out = []
    if bt is None:
        return out
    for fr in bt.findall("frame"):
        fr = resolve(fr)
        b = fr.find("binary")
        b = resolve(b) if b is not None else None
        out.append((fr.get("name") or "?", b.get("name") if b is not None else "?"))
    return out

GROUPS = [
    ("tic (P_Ticker/G_Ticker/thinkers)", re.compile(r"^(P_Ticker|G_Ticker|P_RunThinkers|TryRunTics|P_MobjThinker|P_PlayerThink|P_XYMovement|P_ZMovement)$")),
    ("render: BSP + sprites (R_RenderPlayerView)", re.compile(r"^(R_RenderPlayerView|R_RenderBSPNode|R_AddSprites|R_DrawSprite|R_ProjectSprite|R_DrawMasked|R_Subsector|R_AddLine|R_StoreWallRange|R_RenderSegLoop|R_DrawPlanes|R_MakeSpans)$")),
    ("render: column/span inner loops (R_Draw*)", re.compile(r"^(R_DrawColumn|R_DrawSpan|R_DrawFuzzColumn|R_DrawTLColumn|R_DrawTranslatedColumn|R_DrawColumnInCache|R_DrawSpan.*|R_DrawColumn.*|R_DrawMaskedColumn)$")),
    ("display + status bar (D_Display/ST_/HU_)", re.compile(r"^(D_Display|ST_Drawer|HU_Drawer|ST_Ticker|AM_Drawer|V_DrawPatch.*|V_DrawPatchTranslated)$")),
    ("present (I_FinishUpdate/SDL/Metal)", re.compile(r"^(I_FinishUpdate|SDL_RenderPresent|SDL_UpdateTexture|SDL_RenderTexture|.*Metal.*|.*MTL.*|CAMetal.*|I_ResetScreen|I_GetTime.*)$")),
    ("sound (S_/I_.*Sound/SDL audio/OpenAL)", re.compile(r"^(S_UpdateSounds|S_Update|I_UpdateSound|I_UpdateSoundParams|I_StartSound|I_OAL.*|alSource.*|al[A-Z].*|SDL_.*Audio.*|.*AudioUnit.*|.*CoreAudio.*|.*Synth.*|EAS_.*|.*Fluid.*)$")),
    ("input/pump (SDL events, UIKit)", re.compile(r"^(I_StartTic|I_GetEvent|SDL_PumpEvents|SDL_PollEvent|UIKit_PumpEvents|.*UIApplication.*|.*UIEvent.*)$")),
    ("wait/sleep (kernel)", re.compile(r"^(__psynch.*|mach_msg.*|__semwait.*|__ulock.*|semaphore_.*|usleep|nanosleep|__select|kevent.*|pthread_cond.*|SDL_Delay.*|I_Sleep.*)$")),
]

per_thread = collections.Counter()      # weight ns
per_thread_samples = collections.Counter()
per_core = collections.Counter()
self_syms = collections.Counter()
self_syms_main = collections.Counter()
incl_groups = collections.Counter()
state = collections.Counter()
total = 0
tmin = None; tmax = None
main_tid = None

for row in root.iter("row"):
    st = resolve(row.find("sample-time"))
    t = int(st.text)
    tmin = t if tmin is None else min(tmin, t); tmax = t if tmax is None else max(tmax, t)
    th = resolve(row.find("thread"))
    tname = th.get("fmt") or "?"
    tname = re.sub(r" \(Waddle, pid: \d+\)", "", tname)
    w = resolve(row.find("weight")); wn = int(w.text)
    core = resolve(row.find("core")); cname = core.get("fmt") or "?"
    ts = resolve(row.find("thread-state")); sname = ts.text or "?"
    total += wn
    per_thread[tname] += wn; per_thread_samples[tname] += 1
    per_core["E core" if "E Core" in cname else ("P core" if "P Core" in cname else cname)] += wn
    state[sname] += wn
    frames = frames_of(row.find("tagged-backtrace"))
    if frames:
        leaf = frames[0]
        self_syms[f"{leaf[0]}  [{leaf[1]}]"] += wn
        if tname.startswith("Main Thread"):
            self_syms_main[f"{leaf[0]}  [{leaf[1]}]"] += wn
    names = [f[0] for f in frames]
    seen = set()
    for label, rx in GROUPS:
        if any(rx.match(n) for n in names):
            if label not in seen:
                incl_groups[label] += wn; seen.add(label)

dur_s = (tmax - tmin) / 1e9 if tmin is not None else 0
ms = lambda ns: ns / 1e6
print(f"samples: {sum(per_thread_samples.values())}  total CPU {ms(total):.0f} ms over {dur_s:.1f} s of trace  "
      f"= {ms(total)/dur_s/10:.1f}% of one core")
print("\n== CPU by thread (ms, % of process CPU)")
for name, wn in per_thread.most_common(12):
    print(f"  {ms(wn):8.0f} ms  {100*wn/total:5.1f}%  {name}")
print("\n== CPU by core type")
for name, wn in per_core.most_common():
    print(f"  {ms(wn):8.0f} ms  {100*wn/total:5.1f}%  {name}")
print("\n== thread state of samples")
for name, wn in state.most_common():
    print(f"  {ms(wn):8.0f} ms  {100*wn/total:5.1f}%  {name}")
print("\n== inclusive share of process CPU by engine phase (a sample counts once per phase it passes through)")
for label, _ in GROUPS:
    wn = incl_groups[label]
    print(f"  {ms(wn):8.0f} ms  {100*wn/total:5.1f}%  {label}")
print("\n== top self symbols, whole process")
for name, wn in self_syms.most_common(22):
    print(f"  {ms(wn):8.0f} ms  {100*wn/total:5.1f}%  {name}")
print("\n== top self symbols, main thread")
mt = sum(self_syms_main.values()) or 1
for name, wn in self_syms_main.most_common(18):
    print(f"  {ms(wn):8.0f} ms  {100*wn/mt:5.1f}%  {name}")

# ---- exclusive attribution on the main thread: walk from the leaf up and
# charge the sample to the first phase that claims a frame, so each sample
# lands in exactly one bucket and the buckets sum to the thread.
PHASES = [
    ("present: Metal/CoreAnimation/SDL render (I_FinishUpdate)", re.compile(r"^(I_FinishUpdate|SDL_RenderPresent|SDL_UpdateTexture|SDL_RenderTexture|SDL_RenderClear|CAMetal.*|.*MTL.*|.*Metal.*|CA::.*)$")),
    ("render: columns/spans (R_Draw*, DrawPatchColumn, DrawMaskedColumn)", re.compile(r"^(R_Draw.*|DrawPatchColumn|DrawMaskedColumn|R_MapPlane|do_draw_plane|R_MakeSpans|R_GetColumn)$")),
    ("render: BSP/segs/sprites/planes (R_RenderPlayerView tree)", re.compile(r"^(R_RenderPlayerView|R_RenderBSPNode|R_Subsector|R_AddLine|R_StoreWallRange|R_RenderSegLoop|R_AddSprites|R_ProjectSprite|R_DrawSprite|R_DrawMasked|R_DrawPlanes|R_DrawPSprite|R_SetupFrame|R_.*)$")),
    ("status bar + HUD + patches (ST_/HU_/V_)", re.compile(r"^(ST_.*|HU_.*|V_.*|AM_.*|M_Drawer|MN_Drawer)$")),
    ("tic (G_Ticker/P_Ticker/thinkers)", re.compile(r"^(G_Ticker|P_Ticker|P_RunThinkers|TryRunTics|P_.*|G_.*|A_.*|EV_.*|T_.*)$")),
    ("sound (S_* on the main thread)", re.compile(r"^(S_.*|I_UpdateSound|I_StartSound|I_OAL.*|al[A-Z].*)$")),
    ("D_Display glue / wipe / other engine", re.compile(r"^(D_Display|D_DoomLoop|D_.*|I_StartTic|I_GetTime.*|I_.*|W_.*|Z_.*)$")),
    ("SDL event pump / UIKit / SwiftUI on main", re.compile(r"^(SDL_.*|UIKit_.*|.*UIApplication.*|.*UIEvent.*|.*CFRunLoop.*|.*SwiftUI.*|objc_.*)$")),
]
main_excl = collections.Counter(); main_total = 0
for row in root.iter("row"):
    th = resolve(row.find("thread")); tname = th.get("fmt") or ""
    if not tname.startswith("Main Thread"): continue
    wn = int(resolve(row.find("weight")).text); main_total += wn
    names = [f[0] for f in frames_of(row.find("tagged-backtrace"))]
    bucket = "other (libc/kernel/unknown leaf, no engine frame matched)"
    for n in names:
        hit = next((label for label, rx in PHASES if rx.match(n)), None)
        if hit: bucket = hit; break
    main_excl[bucket] += wn
print(f"\n== main thread, exclusive by phase (sums to {ms(main_total):.0f} ms)")
for label, wn in main_excl.most_common():
    print(f"  {ms(wn):8.0f} ms  {100*wn/main_total:5.1f}%  {label}")

# ---- what the busiest non-main threads are doing
per_thread_syms = collections.defaultdict(collections.Counter)
for row in root.iter("row"):
    th = resolve(row.find("thread")); tname = re.sub(r" \(Waddle, pid: \d+\)", "", th.get("fmt") or "")
    if tname.startswith("Main Thread"): continue
    wn = int(resolve(row.find("weight")).text)
    fr = frames_of(row.find("tagged-backtrace"))
    names = [f[0] for f in fr]
    # the deepest engine/library frame that is not a kernel/pthread leaf
    tag = next((n for n in names if not re.match(r"^(start_wqthread|_pthread_.*|__.*|mach_msg.*|iokit_.*|kevent.*|_dispatch_.*|thread_start|0x[0-9a-f]+)$", n)), names[0] if names else "?")
    per_thread_syms[tname][tag] += wn
print("\n== busiest non-main threads: top frames (ms)")
for tname, wn in per_thread.most_common(6):
    if tname.startswith("Main Thread"): continue
    print(f"  -- {tname}: {ms(wn):.0f} ms")
    for sym, w2 in per_thread_syms[tname].most_common(5):
        print(f"       {ms(w2):7.0f} ms  {sym[:90]}")
