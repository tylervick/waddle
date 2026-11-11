# An engine session costs an iPhone 15 Pro about an eighth of one efficiency core

Measured 2026-11-10, issue #246. Verdict first: **measured, nothing
actionable, at these numbers, on this date.** The main-thread-blocking
design (`WoofIOS_Run` owns the main thread for the whole session while SDL
pumps UIKit) costs nothing the phone notices: the session runs almost
entirely on the efficiency cores, and the main thread is idle seven eighths
of every frame. This file exists so that stops being an open question and
becomes a number to compare against.

## Conditions

Recorded with `Scripts/profile-session.sh --signing development --template
'Time Profiler' --runs 2` and summarised with `Scripts/profile-summary.py`
(both on the branch that added this file). Every condition is also in the
`conditions.json` beside each trace.

| | |
|---|---|
| Device | Computron, iPhone 15 Pro (`iPhone16,1`, A17 Pro: 2 P + 4 E cores), iOS 27.2 (24B119), wired |
| App | commit `cfe7b82`, Release, development-signed, clean tree; engine fingerprint `184e4a90…` (Woof! 16.0.0 pin `1462fadc`) |
| Workload | Freedoom Phase 2 `DEMO1`, MAP03, skill 3, 2664 tics (76.1 s at 35 Hz), `-playdemo` then `-timedemo`, `-nogui`, nobody touching the phone |
| Display | `uncapped` on and `vsync` on (Woof! defaults), no `CADisableMinimumFrameDurationOnPhone` in the plist, so iOS presents at most 60 frames per second |
| Template | Time Profiler, 1 ms sampling. Processor Trace needs an iPhone 16; this is a 15 |
| Traces | `~/Downloads/waddle-profile-246-2026-11-10/` (four `.trace` bundles, 9–12 MB each, plus both `conditions.json`) |

## The numbers (playdemo, real time)

Two runs, 77.9 s of trace each (launch, title, the 76 s demo, exit).

| | run 1 | run 2 |
|---|---|---|
| Process CPU, all threads | 18 176 ms (23.3 % of one core) | 18 416 ms (23.7 %) |
| on E cores / on P cores | 97.7 % / 2.3 % | 97.8 % / 2.2 % |
| Main thread | 9 645 ms (12.4 % of one core) | 9 348 ms (12.0 %) |
| SDL audio thread (SONiVOX synth, ebur128, reverb, SDL's delay spin) | 2 567 ms | 2 629 ms |
| Metal command-buffer submission, spread over 5–7 GCD workers | ≈ 5 300 ms total | ≈ 6 100 ms total |
| `AURemoteIO::IOThread` | 428 ms | 328 ms |

Main thread, each sample charged to exactly one phase (walking up from the
leaf to the first engine frame):

| phase | run 1 | run 2 | per 60 Hz frame (run 1, ≈ 4 570 frames) |
|---|---|---|---|
| column/span inner loops (`R_DrawColumn`, `R_DrawSpan`, `DrawPatchColumn`, `R_MapPlane`…) | 3 352 ms | 2 790 ms | 0.73 ms |
| present (`I_FinishUpdate` → SDL → Metal/CoreAnimation) | 2 701 ms | 2 576 ms | 0.59 ms |
| SDL event pump / UIKit run loop on the main thread | 1 587 ms | 2 164 ms | 0.35 ms |
| BSP walk, segs, sprites, planes (`R_RenderPlayerView` tree) | 1 317 ms | 1 235 ms | 0.29 ms |
| status bar + HUD patches | 227 ms | 188 ms | 0.05 ms |
| **tic** (`G_Ticker`, `P_Ticker`, thinkers) | **218 ms** | **211 ms** | **0.08 ms per 35 Hz tic** |
| `D_Display` glue, wipe, other engine | 112 ms | 81 ms | |
| sound bookkeeping on main | 44 ms | 38 ms | |

So a frame costs the main thread about **2.1 ms of its 16.7 ms budget**:
roughly 1.1 ms rendering, 0.6 ms handing the picture to Metal, 0.35 ms
pumping UIKit, and the game simulation itself is noise, 0.08 ms per tic.
Hottest self symbols, whole process: `iokit_user_client_trap` 1.8 s (GPU
submission), `start_wqthread` 1.8 s, `mach_msg2_trap` 1.6 s, `R_DrawColumn`
1.28 s, `R_RenderSegLoop` 0.66 s, `R_DrawSpan` 0.62 s, `memmove` 0.47 s,
`DrawPatchColumn` 0.46 s, `VMAddSamples` 0.43 s, `ebur128_calc_gating_block`
0.36 s.

## The ceiling (timedemo)

`-timedemo` renders one frame per tic as fast as the device allows. Both runs
took 46.2 s and 46.1 s of trace for 2664 tics: 2664 ÷ 60 is 44.4 s, so the
run was pinned to the 60 Hz present, and the main thread was busy 5 792 ms
and 5 832 ms of it, 12.5 %. The phase split is the same as above. The raw
render ceiling is therefore not measurable with vsync on, and does not need
to be: at the only frame rate the display offers, the main thread has
roughly 85 % headroom, and that headroom sits on efficiency cores the
scheduler never saw a reason to leave.

## What this answers, and what it does not

- *Does blocking the main thread for the session cost anything?* No. The
  thread is idle most of each frame and UIKit's own work on it (the overlay,
  the run loop) is 0.35–0.47 ms per frame. If the overlay ever grows into
  something that needs a full SwiftUI layout per frame, re-measure.
- *Does anything meaningful run off the session thread?* Audio and GPU
  submission. The SDL audio thread is the second-busiest thread, and about
  1 s of its 2.6 s is SDL's own delay-and-poll spin (`SDL_SYS_DelayNS`,
  `clock_get_time`), 1.3 % of a core: noticed, not worth an issue. Metal
  submission is spread across GCD workers and totals 6–8 % of a core.
- *Is the 35 Hz tic or the uncapped renderer the cost?* The renderer, by
  more than ten to one, and the renderer is the classic column and span
  loops. There is no hot path worth an issue of its own at a 2 ms frame.
- Not measured: a modern megawad with thousands of sprites in view, a 120 Hz
  presentation (needs the plist key), power draw (Power Profiler is the
  second pass #246 mentioned), and anything on an iPad.

## How to redo it

Phone unlocked and attached, Developer Mode on, from a clean tree:

```sh
Scripts/profile-session.sh --signing development --template 'Time Profiler' --runs 2
Scripts/profile-session.sh --signing development --template 'Time Profiler' --runs 2 --mode timedemo
Scripts/profile-summary.py build/profile-session/<run dir>/run-1.trace
```

`--signing development` exists because the Release configuration is pinned
to the App Store distribution profile that only the CI runner holds; the
binary is the same, and `conditions.json` records which signing was used.
Compare the main-thread phase table and the E/P split; a result that moves
the tic above a millisecond, the main thread above a quarter of a core, or
the work onto the P cores is the signal this baseline is for.
