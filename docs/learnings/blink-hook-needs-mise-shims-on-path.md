# A user-level agent hook cannot see a project-pinned mise tool

`blink setup claude-code` writes this into the **user-level**
`~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`) — not into
anything in this repository:

```json
{ "type": "command", "command": "blink review --hook claude-code" }
```

The command is a bare name. That is fine for the vendor's own install path,
which drops a binary in `~/.local/bin` and tells you to put that on `PATH`.
It is not automatically fine here, because `mise.toml` pins the CLI instead
(`[tools."http:blink"]`), and a mise-managed tool answers a bare name in only
two ways:

- **inside** a `mise run` task or an activated shell, where mise has put the
  tool's install directory on `PATH` — which a hook is not; or
- through the **shims** directory (`~/.local/share/mise/shims/blink`, a
  symlink to `mise` itself), which resolves the tool by reading the config for
  the current working directory.

Hooks run outside the first and therefore depend entirely on the second. mise
does not put the shims directory on `PATH` for you: `mise activate` deliberately
does not, preferring the install directories, so a contributor who set mise up
that way has a working `blink` at every prompt and a hook that dies with
`blink: command not found` at the end of every agent turn.

The confusing part is the asymmetry. `mise run blink-setup` succeeds, `blink
--version` succeeds, `which blink` prints a path — and the thing those commands
prove is not the thing the hook needs. Verifying by running `blink` from a
shell where mise is active cannot distinguish the two cases; only the inherited
`PATH` can:

```sh
# from a mise task: the install dir is on PATH here regardless, so probing with
# `command -v blink` always succeeds and proves nothing.
case ":$PATH:" in
  *":${MISE_DATA_DIR:-$HOME/.local/share/mise}/shims:"*) ;; # hook will resolve
  *) ;;                                                     # hook will not
esac
```

The same trap applies to any future user-level agent hook that shells out to a
tool this repository pins, which is why it is worth a file rather than a
comment.

## The check

`mise run blink-setup` ends with exactly the test above and fails with the
`export PATH=` line to paste if the shims directory is missing. It cannot be a
CI check: the file it would have to inspect is each contributor's own
`~/.claude/settings.json`, which is outside the repository by design — the
`.gitignore` here excludes `.claude/*`, and whether to run an agent review hook
at all is a per-machine choice.
