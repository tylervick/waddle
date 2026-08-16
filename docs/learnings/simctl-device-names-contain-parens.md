# A simulator's name can contain parentheses, so parse the line from the right

`xcrun simctl list devices available` prints one device per line as

```
    iPad Pro 13-inch (M4) (8BAE6A3E-5E4C-4F2F-A390-EEB8845BC5BB) (Booted)
    iPhone 17 Pro (A44DCE97-EEEC-4E37-A84C-BA535DC8CBB1) (Shutdown)
```

Recovering the device name by cutting at the first ` (` works on every phone
and on nothing else. Every iPad carries a parenthesised generation in its own
name — `iPad Pro 13-inch (M4)`, `iPad (A16)` — so that cut yields
`iPad Pro 13-inch`, which matches nothing the caller asked for.

`Scripts/check-simulator-available.sh` did exactly that from the day it was
written. It never mattered, because the only destination this repo had was a
phone. The moment `ci.yml` gained an iPad leg (issue #131), the guard reported
a device sitting right there in the listing as a *genuine destination pin
problem* — the one failure shape it deliberately does not mark as re-runnable
infrastructure, so the job would have failed hard and told the reader to go fix
a pin that was already correct.

Peel the two trailing parenthesised fields off the **right** instead. They are
always `(<udid>) (<state>)`, and nothing else is appended after them:

```awk
sub(/[[:space:]]+$/, "", line)   # simctl emits a trailing space on some lines
name = line
sub(/ \([^()]*\)$/, "", name)    # (Booted)
sub(/ \([^()]*\)$/, "", name)    # (<udid>)
```

Both `Scripts/check-simulator-available.sh` and
`Scripts/ensure-ipad-simulator.sh` parse it this way, and
`Scripts/test-check-simulator-available.sh` covers it with a fixture holding
both `iPad Pro 13-inch (M4)` and a device genuinely named `iPad Pro 13-inch`,
so a parser cannot pass by substring-matching instead.

## The other half: `{n}` intervals do not work in macOS awk

The obvious fix — one `awk` that matches the UDID with `/\([0-9A-F-]{36}\)/` —
silently matches nothing. macOS ships BWK awk, which does not implement
interval expressions; the pattern is not an error, it just never fires. Select
the line in `awk` and extract the UDID with `sed -n -E '...p'`, which does
support them. `Scripts/capture-screenshots.sh` already used `sed` for this.
