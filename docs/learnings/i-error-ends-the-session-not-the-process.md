# `I_Error` ends the session, not the process

Found 2026-09-29 while fixing issue #38.

Upstream Woof! treats an `I_Error` path as the end of the program: whatever
it abandons, the OS takes back a moment later. So upstream code, and reviews
of our patches, call a leak on an error path "unreachable" or not worth
fixing. #38 was deferred from the Plan 1 review as exactly that: "AddWadInMem
data buffer leak (unreachable)".

On iOS, `I_Error` longjmps back into `WoofIOS_Run` (`woof_ios.c`). The launcher
shows "Couldn't run this game", and the next game runs in the same process. So
an error path is a session-end path, and anything it abandons is gone for the
rest of the launch. It is also reachable: a player imports a broken zip, and
all four of `AddWadInMem`'s `I_Error`s fire on nothing more than a bad CRC, a
short or mislabelled WAD header, or a lump that runs past the end.

Two consequences:

- **An error-path leak is a per-session leak.** Free before the `I_Error`, or
  hand the allocation to something that is torn down at session end.
  `W_Close` is registered with `I_AtExitPrio(..., true, ...)` (run on error)
  before `D_DoomMain` loads any file, so a module's `Close` is a safe owner for
  anything allocated while loading.
- **"The process exits" is not an ownership model here.** Upstream often keeps
  an allocation alive for the rest of the program on purpose: a zip's
  decompressed WADs are pointed into by `lumpinfo_t.data` and never freed.
  That is a leak once per session here, and nothing about the error paths
  hints at it. Ask of every allocation on a load path who frees it when the
  session ends, not only on the error paths.

Test pattern for an error path without a fixture file: build the broken input
in the UI test and pass it to the app in the launch environment.
`SessionStartStateTests.testWadsInsideZipsAreFreedAfterEverySession` builds a
stored (uncompressed) zip with a hand-computed CRC-32, base64-encodes it into
`WADDLE_TEST_ZIP_<n>`, and `EngineSession` writes it to a temporary file and
adds `-file`. `WADDLE_TEST_NOGUI` keeps SDL's own error box away, since XCUITest
cannot dismiss it. Assert on the launcher alert's message too, so each broken
input is proven to fail at the path it was built for.
