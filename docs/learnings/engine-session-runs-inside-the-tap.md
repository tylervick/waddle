# The engine session must not run inside the tap that started it

Found 2026-09-29 while fixing issue #95.

`EngineSession.play` runs the engine synchronously on the main thread until the
session ends. `ShelfView.play` used to call it straight from the tile's button
action, so every session ran nested inside UIKit's dispatch of that one tap. A
`sample` of the stuck app showed the whole chain on the main thread:

```
UIApplication sendEvent → UIWindow sendEvent → UIGestureEnvironment _updateForEvent
  → … _UIGestureRecognizerSendActions → SwiftUI ButtonAction → ShelfView.play
  → EngineSession.play → WoofIOS_Run → D_DoomMain → … → I_SafeExit
  → SDL_ShowSimpleMessageBox → -[NSRunLoop runMode:beforeDate:]
```

While that tap is still being dispatched, UIKit does not deliver another
gesture recognizer's action. Raw touches still arrive: gameplay worked, because
SDL's view and the overlay read `touchesBegan`, and SDL's error box drew OK as
pressed. But `UIAlertController` fires its actions through gesture recognizers,
so OK never did anything. After an `I_Error` the app needed a force quit.

**Fix:** `ShelfView.play` schedules the session with `CFRunLoopPerformBlock` on
the main run loop, so it starts after the tap's dispatch has returned. The
experiment that proved the cause changed only that, and one tap then
dismissed the box.

**Not `DispatchQueue.main.async`, and not a `@MainActor` `Task`.** Either
would run the session inside a main-queue block, and the main queue is serial:
every other block queued to it would wait until the session ended, including
the UI tests' autoquit (`WADDLE_AUTOQUIT_SECONDS`), which quits the session
from `DispatchQueue.main.async`. A run-loop block leaves the main queue free
for the nested run loops SDL pumps.

**A test seam hid this.** Every test that made a session fail set
`WADDLE_TEST_NOGUI`, whose comment said SDL's box "runs a modal loop an
XCUITest tap does not dismiss". That was the bug itself, recorded as a
limitation of the test tool. When a seam exists because the real path "doesn't
work under XCUITest", check whether it works for a user before believing it.
`EngineErrorAlertDismissalTests` now runs the production path (no `-nogui`) for two
error sessions in a row, and is the check.
