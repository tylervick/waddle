# `env VAR=value some_function` fails at `env`, with a misleading error downstream

`env` execs a new process image by looking up a literal file on `PATH`. A
shell function isn't a file — it exists only inside the interpreter that
defined it — so `env VAR=value some_function args...` fails with `env:
some_function: No such file or directory` (exit 127) before `some_function`
ever runs, regardless of whether the function was `export -f`'d.

The draft of `Scripts/test-whats-to-test.sh`'s PROCESSING-build case needed to
override `WHATS_TO_TEST_POLL_ATTEMPTS` for one call to the `attach` helper (a
shell function), and reached for the obvious-looking `env
WHATS_TO_TEST_POLL_ATTEMPTS=2 attach "$r" 207`. This does not fail silently —
`env`'s own non-zero exit propagates, so a naive `if out="$(...)"; then fail
...; fi` guard correctly treats it as a failure. What it does instead is
worse in a different way: it fails for the **wrong reason**, and the assertion
right after it (`case "$out" in *207*) ... esac`) reports a *misleading*
diagnostic — `"error does not name the build number; got: "` — that reads
exactly like an implementation bug (the script's error message doesn't
mention the build number) when the real cause is that the implementation
never ran at all. Chasing that message leads to the wrong file.

**Fix**: drop `env` and use a plain variable-assignment prefix on the function
call instead. `VAR=value some_function args...` is standard shell syntax for
setting a variable for the duration of one command, and — unlike `env` —
applies to shell functions and builtins exactly as it does to external
binaries:

```bash
if out="$(WHATS_TO_TEST_POLL_ATTEMPTS=2 attach "$r" 207)"; then
```

**One qualifier, and it is not academic**: for a *function* or *special
builtin*, whether the assignment survives the call depends on POSIX mode.
Measured on bash 3.2.57 (macOS), same one-liner both ways:

| Mode | `V=x f; echo "${V:-unset}"` after the call |
|---|---|
| default | `unset` — the assignment is scoped to the call |
| `set -o posix` | `x` — the assignment **persists in the calling shell** |

POSIX specifies the persisting behaviour for functions and special builtins;
bash's default is the more useful non-POSIX one, and `sh`-invoked or
posix-mode scripts get the other. So the form is safe *and* scoped here
because this suite is `#!/bin/bash` without `set -o posix` — not because
assignment prefixes are inherently non-leaking. In a posix-mode script, save
and restore the variable explicitly instead of assuming the call scopes it.

## Not yet an executable check

A lint could flag `env` followed by a bareword that resolves to a currently
defined shell function rather than a file on `PATH`, but that requires
knowing the set of defined functions at lint time, which a static grep does
not have. Until then, this file is the check: when a per-case environment
override is needed for a shell-function test helper, reach for the
assignment-prefix form first, not `env`.
