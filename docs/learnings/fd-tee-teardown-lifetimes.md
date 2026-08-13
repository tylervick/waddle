# Tearing down an fd tee has two lifetime traps, plus a contamination guard

`SessionLogCapture` (`App/Sources/Diagnostics/SessionLogCapture.swift`) tees
stdout/stderr through a pipe: a pump thread reads the pipe and passes each
chunk through to a `dup`'d copy of the original fd (`saved`) while also
writing it to the session log. Getting teardown (`end()`) right took two
tries.

**Trap 1 — closing `saved` immediately after `dup2(saved, target)` races the
pump thread's pass-through write.** Restoring `target` looks like the moment
`saved` is safe to close: the process's own reference to the original
destination is back in place. It isn't. The pump thread almost never has
reached its first `read` yet — a freshly spawned thread is slow to get
scheduled — so it is still holding `saved` open when a naive teardown closes
it out from under it, and the pump's very next `write(saved, ...)` fails with
`EBADF`. This is not a rare interleaving: the closer wins the race near
every time, which is what makes it easy to ship and then hit constantly in
practice.

**Trap 2 — a straggler abandoned by the bounded teardown deadline must leak
its fds, not close them.** `end()` waits for pump threads to finish, but only
up to `drainDeadline`: a permanently blocked pass-through write must not hang
teardown forever. A thread still running past the deadline is abandoned, but
its fds must NOT be closed on its behalf. fd numbers are reissued
lowest-available, so closing them lets some unrelated `open()` claim that same
number while the straggler is still blocked inside `write(saved, ...)`. When
the straggler's write finally unblocks, it lands in whatever object now holds
that fd number — for example the next session's log file, silently corrupting
it. A leaked fd on this path is bounded (at most one per abandoned pump) and
harmless; a reissued fd written to by a straggler is silent corruption, which
is strictly worse.

**The contamination guard.** Trap 2 means a straggler can still be alive when
a new session begins. It is kept from writing into that new session with a
lock-guarded session epoch: every `begin()` bumps `sessionEpoch` under
`logLock`, and each pump thread captures the epoch it was spawned with and
checks it in the *same* lock acquisition as its log write. A straggler whose
epoch no longer matches skips the write instead of touching the current
session's log.

**What the tee cannot capture.** It only sees bytes that actually reach the
fd. Engine output still buffered in libc stdio at the moment of a crash never
reaches the pipe and is lost — MetricKit is what covers the crash itself, not
this tee.

**The executable check:** the deterministic teardown test in
`App/Tests/SessionLogCaptureTests.swift`,
`testEndReturnsBoundedOnATimedOutPassThroughAndTheStragglerNeverContaminatesALaterSession`.
It fills a real pipe to capacity so the pass-through genuinely blocks, then
asserts `end()` still returns near `drainDeadline` and that the straggler's
bytes never land in a later session's log. Read that test for the exact
mechanics rather than restating them here.

**Provenance:** hit while building `App/Sources/Diagnostics/SessionLogCapture.swift`
for diagnostics export.
