# The writable-globals diff cannot see two kinds of leak

Found 2026-09-23 while classifying its output for issue #266
(`docs/engine-session-globals.md`).

**What session 1 got to decides what the list can contain.** Two Freedoom
Phase 2 sessions with the probe's default 12 s autoquit list 168 engine
variables; the same pair at 40 s lists 442. Phase 2's title page lasts about
11 s, so the short run quits before any demo loads a level and every piece of
level state is simply absent from the list. The run is not wrong, it is
partial, and the counts do not say so. `GlobalsDiffProbeTests` takes
`TEST_RUNNER_WADDLE_GLOBALS_DIFF_AUTOQUIT`; take a short and a long run and
classify the union.

**A leak that writes the same bytes both times is invisible.** The diff
compares session 1's snapshot with session 2's. If a table is patched in place
with the same values each session, or a stale pointer keeps pointing at the
same object, the bytes match and the variable never appears. Three real leaks
were missed that way and found only by reading the code around the ones that
did show:

- `mus_playing` (`s_sound.c`) still named the previous session's title track,
  so a session after a quit at the title opened in silence. The diff showed
  only a side effect in `i_oalmusic.c` (`player_thread_running 1 -> 0`, 12 s
  run only).
- `autoload_paths` (`d_main.c`) doubled every session. The diff showed
  `next_priority` 13 -> 25 in `w_wad.c`, whose own reset is correct.
- DEHACKED string substitutions (`deh_strings.c`'s `hash_table`): both
  Freedoom IWADs replace the same strings, so even the cross-game run is
  byte-identical (#270).

So treat a variable in the list as a pointer to a *module*, and read that
module's other statics too. A cross-game pair helps, but only where the two
games write different values.

`WaddleUITests/SessionStartStateTests` is the executable check for the leaks
fixed so far: it captures each at the diff's checkpoint and fails, naming the
field, when a session starts differently from a fresh process.
