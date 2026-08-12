# Command substitution around a function call discards everything but its stdout

`x="$(f)"` forks a subshell to run `f` and captures only what `f` writes to
stdout. Bash does this for every command substitution, not just external
commands — calling a shell *function* this way is exactly as isolating.
Anything `f` does that isn't "write to stdout" happens in that forked process
and vanishes the instant it exits:

```bash
REVERTED=""
f() { REVERTED="hello"; }
x="$(f)"
echo "$REVERTED"   # prints nothing -- the assignment never left the subshell
```

This bit `Scripts/check-red-green.sh` for two effects at once, both inside the
same call:

```bash
sw="$(classify_domain swift "$(swift_src)" "$(swift_test)")"
```

`classify_domain` calls `revert_src`, which sets the global `REVERTED` so the
`EXIT` trap knows what to put back. Run this way, that assignment landed in
the subshell and was gone before `restore_tree` ever ran — the tree stayed
reverted and dirty. Separately, a test hook inside `classify_domain` calls
`exit 70` to simulate a hard failure; run inside `$(...)`, that `exit` only
killed the subshell. The assignment `sw="$(...)"` picked up exit status 70,
but the *script* kept going — a hard failure that should have stopped
everything didn't.

**Fix — run the callee directly, capture output via redirection instead:**

```bash
verdict_tmp="$(mktemp)"
classify_domain swift "$(swift_src)" "$(swift_test)" > "$verdict_tmp"
sw="$(cat "$verdict_tmp")"
```

`classify_domain ... > file` redirects file descriptor 1 for that one command
without forking anything — `classify_domain` runs in the current shell, so its
writes to global variables and its `exit` calls are real. `sw="$(cat file)"`
is a command substitution too, but the only thing in that subshell is `cat`,
which doesn't touch shell state, so it's harmless the same way `$(swift_src)`
elsewhere in this script is harmless: capturing a function that has no side
effects beyond its own stdout costs nothing.

## Not the same failure as a masked exit status

[Masking a query's exit status makes a guard fail open](masked-exit-status-fails-open.md)
is about a *different* mechanism: `cmd || true` or `2>/dev/null` throwing away
the evidence that a command failed, so a failure gets misread as a meaningful
(usually permissive) answer. Nothing here is masked — `classify_domain`'s
`exit 70` is not swallowed by `|| true` or a redirect to `/dev/null`; it
propagates faithfully as the exit status of `sw="$(...)"`. The problem is one
level further up the shell's process model: the subshell a command
substitution forks throws away the callee's *shell-level* side effects —
variable assignments, `exit` — independent of whether anything about its
status or output was ever masked. A perfectly unmasked, perfectly honest
`exit 70` still doesn't stop the script, because it never reaches the process
that's running the script.

It is the same family as the `while | subshell` trap called out inline in
`Scripts/check-red-green.sh` (a piped `while read` loop also forks a subshell,
for the same reason, and loses variables assigned inside it the same way) —
just one call shape further out: there it's a pipeline, here it's `$(...)`
wrapped around a whole function call.
