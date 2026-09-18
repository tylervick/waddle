# A "most recently played, else newest created" sort breaks when only one side uses epoch dates

`LibraryService.games()` (and `allLoadouts()` before it) sorts descending by
`$0.lastPlayed ?? $0.createdAt`. That comparator only works if `lastPlayed` and
`createdAt` are drawn from the same timeline — and `createdAt` always is: every
model gives it `= .now`, so a freshly created, never-played row's fallback key
is *real wall-clock time*, right now.

A test that wants "the played rows outrank the unplayed one" has to give the
played rows a `lastPlayed` that is later than that row's `createdAt` — not
earlier, not "old-looking". `Date(timeIntervalSince1970: 100)` (1970-01-01
00:01:40 UTC) reads as "an old play session" to a human, but it is a *tiny*
number next to `Date.now`'s (~1.7 billion-plus seconds). Comparing it against a
never-played row's `createdAt` fallback, 1970 loses — the never-played row
sorts *first*, exactly backwards from what the test asserts:

```swift
// Wrong: base's createdAt (~Date.now, e.g. 1.79e9) beats both of these.
try service.markPlayed(old,    at: Date(timeIntervalSince1970: 100))
try service.markPlayed(recent, at: Date(timeIntervalSince1970: 200))
XCTAssertEqual(try service.games().map(\.name), ["Recent", "Old", base.displayName])
// Actual: ["doom2", "Recent", "Old"]
```

**Fix:** anchor the fixture's played-dates to the same clock the fallback
uses, not to the epoch:

```swift
try service.markPlayed(old,    at: Date().addingTimeInterval(100))
try service.markPlayed(recent, at: Date().addingTimeInterval(200))
```

This only bites a comparator with a *mixed-source* fallback (some rows keyed by
a real explicit date, others falling back to `.now`-stamped `createdAt`) and
only when a fixture also creates a never-played row to prove the fallback
ordering. A test that only ever sets `lastPlayed` (no fallback in play) never
hits it.

**Provenance:** games-and-files plan 1, Task 3 (`GameServiceTests.
testGamesSortMostRecentlyPlayedFirstThenNewestCreated`) — the task's own
brief specified the epoch dates verbatim; running the test (not just reading
it) is what surfaced the inversion.
