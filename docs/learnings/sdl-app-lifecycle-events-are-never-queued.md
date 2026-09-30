# SDL never queues the app lifecycle events, so a `ProcessEvent` case cannot see them

Found 2026-09-29 while building issue #111 (pause and save on backgrounding).

SDL3 on iOS turns UIKit's resign-active and did-enter-background
notifications into `SDL_EVENT_WILL_ENTER_BACKGROUND` and
`SDL_EVENT_DID_ENTER_BACKGROUND` (with `SDL_EVENT_WILL_ENTER_FOREGROUND`,
`SDL_EVENT_DID_ENTER_FOREGROUND`, `SDL_EVENT_TERMINATING` and
`SDL_EVENT_LOW_MEMORY` alongside). They look like any other event type, and
the engine's `I_GetEvent` drains the whole queue with `SDL_PeepEvents`, so the
obvious place for a handler is a `case` in `i_video.c`'s `ProcessEvent`.

**That case never fires.** `SDL_SendAppEvent` (`Vendor/src/SDL/src/events/SDL_events.c`)
does not push these six types onto the queue; it calls the event watchers
only, in the notification's own call stack, because iOS may freeze the
process before a queue is ever drained. The header says so, once per type:
"This event must be handled in a callback set with `SDL_AddEventWatch()`."
Measured before the fix: a real Home press and return during a level, the
app's own breadcrumbs recording `active -> inactive -> background -> active`,
and the engine's counters still `bgsave=0 bgpause=0`.

**Fix:** `I_InitGraphics` registers `AppLifecycleWatch` with
`SDL_AddEventWatch` right after `SDL_Init`, and `I_ShutdownGraphics` removes
it, so a second session does not stack a second copy. The watch runs on the
main thread inside the engine's own run-loop pump (`UIKit_PumpEvents`, from
`I_StartTic` or `I_StartDisplay`), which is between tics, so it is safe to
open the menu and write a save from there.

The queued `SDL_EVENT_WINDOW_MINIMIZED` that SDL sends the window just before
`WILL_ENTER_BACKGROUND` is a normal window event and does arrive through
`ProcessEvent`; upstream already uses it to stop drawing.

`BackgroundSuspendTests` is the check: it presses Home mid-level and reads
`bgsave=1 bgpause=1` after the session.
