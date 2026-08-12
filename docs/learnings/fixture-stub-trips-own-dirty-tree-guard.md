# A test double written into the fixture's own working tree trips the guard it's testing

`Scripts/check-red-green.sh` refuses to run at all against a dirty working
tree (`git status --porcelain` non-empty) -- mutating and restoring a tree
that already has uncommitted changes could not be done safely, so it exits
rather than risk it. That refusal does not know or care *why* the tree is
dirty; an untracked file is an untracked file.

Task 4's Swift domain runner needed to stub `xcodebuild`, so its hermetic
test fixtures gained a helper that writes a fake binary and a call log:

```bash
stub_xcodebuild() { # dir, build-rc, test-rc
    mkdir -p "$1/bin"
    cat > "$1/bin/xcodebuild" <<STUB
...
STUB
}
```

Called as `stub_xcodebuild "$r" 65 0`, where `$r` is the fixture repo's own
root -- the same directory `make_repo` already `git init`'d and committed a
base and head into. `bin/xcodebuild` and the `xcb.log` it later appends to
are untracked files inside that repo, created *after* both commits exist.
Every one of these fixtures failed immediately with "refusing to run against
a dirty working tree" -- not because the domain logic was wrong, but because
the test double for an unrelated tool made the fixture itself look dirty to
the exact guard under test.

## The fix

`make_repo` now writes a `.gitignore` (`/bin/` and `/xcb.log`) and commits it
as part of the *base* commit, before any mutate script or stub runs. Ignored
untracked files do not appear in plain `git status --porcelain`, so the
guard's dirty check stays meaningful for everything else while the stub's
own droppings are invisible to it. `stub_xcodebuild`'s paths did not need to
change at all -- the fix belongs in shared fixture setup, not in the tool
double or the individual cases that call it.

## Where else to look

Any test double that writes files into a git fixture repository used by code
under test that itself inspects that repo's cleanliness (a dirty-tree guard,
a "no uncommitted changes" precondition, anything that greps `git status`)
is suspect the same way. The trap is not specific to `xcodebuild` stubs or to
this script -- it is specific to *where* the double's artifacts land. Writing
them outside the repository entirely is the other valid fix; this file chose
`.gitignore` because the brief's given helper and test cases pin the double's
paths to the repo root, and changing that would have meant deviating from
values the task specified verbatim for no functional gain.
