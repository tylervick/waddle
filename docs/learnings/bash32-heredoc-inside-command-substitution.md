# bash 3.2 mis-parses a heredoc inside `$(…)` when its body contains `$"`

macOS ships bash 3.2.57. Its parser scans the body of a command substitution
for the closing `)` by tracking quotes, and it does so **through a heredoc
body**, even a quoted one (`<<'PY'`) whose contents are supposed to be
opaque. A `$"` in that body opens a `$"…"` locale string as far as the
scanner is concerned, every later quote has the wrong parity, and the script
dies at load time with:

```
Scripts/testflight-feedback-digest.sh: line 175: unexpected EOF while looking for matching `"'
```

`bash -n` reports it too, so the shape is detectable before a run. The line
number points at the end of the file, not at the `$"`.

Measured 2026-09-30 while adding a Python regex to
`Scripts/testflight-feedback-digest.sh`:

```bash
counts="$(RENDER="$RENDER" python3 - <<'PY'
heading = re.compile(r"^## (Screenshot feedback|Crash feedback) (\S+)$")
PY
)"
```

The same heredoc had parsed for weeks with only `'s'`/`''` inside it (balanced,
so harmless); `(\S+)$"` broke it. bash 5 parses it correctly, which is why CI
on Ubuntu would not have caught it.

**Fix: do not capture a heredoc-fed command with `$(…)`.** Run it as a plain
command with stdout redirected, then read the file:

```bash
python3 - > "$WORK/counts" <<'PY' \
  || { echo "error: could not parse" >&2; exit 1; }
…
PY
counts="$(cat "$WORK/counts")"
```

This is also the shape `docs/learnings/command-substitution-discards-callee-state.md`
recommends for a different reason (a subshell drops the callee's variable
writes and swallows its `exit`), so a heredoc-fed `$(…)` is wrong twice over
in this repo's scripts.
