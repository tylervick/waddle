# `lockf` without `-k` removes the lock file, so asking "is it free?" can lose the lock

`Scripts/test-duo-pose-device-hub.sh` failed in CI with `FAIL: the holder
never took the lock: ` and an empty log, on trees that touched neither it nor
the hook (issue #453: once on pull request #448, twice running on #452). The
suite's own check for "is the lock held yet" had deleted the lock file.

## The behaviour

`lockf file command` creates `file` if it is missing, and **removes it on the
way out** unless `-k` is given (`man lockf`, macOS 27.2). The suite asked
whether a lock was free with:

```bash
free() { lockf -s -t 0 "$1" true; }
```

When the lock *is* free this takes it, runs `true`, and unlinks the file. A
flock is on the open file, not on the name, so anyone who already has the
file open keeps a perfectly good descriptor to a file nobody else can reach
any more.

The hook takes its lock in two steps, `exec 9>>"$LOCK"` and then
`lockf -s -t 0 9`, with a fork and an exec between them. `start_a_holder`
started the hook and polled `[ -e lock ] && ! free lock` every 50 ms. A poll
that landed between the two steps found the file there and the lock free,
and removed the file. The hook then locked its descriptor, successfully, and
sat in its work holding a lock on a file with no name. The poll saw no file
from then on and gave up after 200 tries: the hook alive, silent, and holding,
which is exactly what the CI log showed, down to the orphaned `sleep` the
runner cleaned up afterwards.

## The reproduction

- By hand: `exec 9>>l; lockf -s -t 0 l true; lockf -s -t 0 9; ls l` — both
  `lockf`s succeed and `l` does not exist.
- Every time: the suite as it was, against a copy of the hook with one line
  added, `sleep 0.3` between opening the lock file and locking it
  (`HOOK=<copy> Scripts/test-duo-pose-device-hub.sh`). It stops at case 24
  with the CI message and an empty log.
- As it happened: the unchanged suite and hook with six `yes > /dev/null`
  running, `STRESS_ROUNDS=60`. Load is what stretches the fork and exec
  between the hook's two steps, and so the window.

The poll holding the lock and keeping the hook out (the issue's first guess)
was not it: the hook retries for 32 s and the poll held the lock for a few
milliseconds in every fifty.

## What the suite does now

- `free` passes `-k`, and case 21 fails if asking ever removes the file.
- "The holder has the lock" is not asked of the lock. The holder's work writes
  a marker file from inside the lock, the suite waits for the marker, and only
  then asks the lock, once, when the holder cannot lose it to the question. A
  hook that reaches its work without the lock fails there.
- The wait is bounded in seconds (`HOLDER_WAIT`, 60), not in polls, and ends
  at once if the process it is waiting for has exited.

## For anything else that uses `lockf`

Give `-k` to every `lockf` that names a file other processes lock too. The
hook itself is unaffected: the descriptor form (`lockf 9`) implies `-k`. And
do not learn whether another process holds a lock by trying to take it,
unless that process is known to be past the point of taking it.
