# `XCUIElement.tap()` returns after the app goes idle, so stamp the clock before it

`EngineSmokeTests` requires each session to live through its whole
`WADDLE_AUTOQUIT_SECONDS` window, measured from the tap on the tile to the
exit label's return. It took its timestamp *after* `play.tap()` returned. On a
hosted runner the first cycle then measured 8.3 s for a 10 s window, with exit
code 0 and nothing wrong in the engine (main run 37287887037, 2026-10-05).

`tap()` is synchronous with the app's event handling, not with the touch: it
synthesises the touch and then waits for the app to report idle before it
returns. Starting an engine session is exactly the moment the main thread is
not idle (SDL creates its window, Metal compiles pipelines, the overlay
installs), so on a slow runner the return trails the real tap by seconds, and
a clock started after it undercounts the session by that much. The error is in
the direction that fails a lower bound while the engine is healthy.

**What to do instead:** take the timestamp before the tap. Every other suite
that measures a session (`SessionStartStateTests`, `DemoLoopReplayTests`,
`CompressedNodesTests`) already did; the smoke test was the outlier. A stamp
before the tap can only overstate the session by the tap's own dispatch
latency, which is milliseconds, not seconds.

**How to tell this from a real early exit:** a real one shows a non-zero exit
label (`EngineErrorAlertDismissalTests`' shape) or a session that ends at a
fixed short time regardless of runner load; this one scales with how slow the
machine is and never reproduces locally.
