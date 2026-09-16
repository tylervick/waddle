# A moved checkout leaves the old absolute path baked into `App/build`

`App/build` is DerivedData, and DerivedData stores **absolute** paths. Move or
rename the checkout and every build after it fails in a way that does not name
the real cause.

Observed 2026-09-16, capturing App Store screenshots for version 1.1. The repo
had been at `/Users/tyler/Documents/doom-ios-2026` and now lives at
`/Users/tyler/Documents/waddle`. `Scripts/capture-screenshots.sh` died with:

```
App/Tests/BreadcrumbLogTests.swift:2:18: error: Unable to find module dependency: 'Waddle'
** TEST BUILD FAILED **
```

which reads as a broken target membership or a missing XcodeGen run — neither of
which was true. The actual signal was hundreds of lines above it, and is a
*warning*, not an error:

```
warning: Stale file '/Users/tyler/Documents/doom-ios-2026/App/build/.../ZIPFoundation.swiftmodule'
         is located outside of the allowed root paths.
```

Every one of those names a directory that no longer exists. The module the
compiler is told to find was built under a path that is gone, so it is never
found, and the failure surfaces as a dependency error in whichever test file
happens to be compiled first.

**The fix is `rm -rf App/build`.** It is gitignored (`.gitignore:10`,
`build/`), it was 1.2 GB, and it regenerates. Nothing in it is worth keeping.

**Why this is easy to misread.** The error names a Swift file and a module, so
the instinct is to suspect the diff, the project file, or a missed `mise run
generate` — and `docs/learnings/xcodegen-source-snapshot-hides-new-tests.md`
trains exactly that instinct for a different symptom. The discriminator is
cheap and unambiguous:

```sh
old_path="/Users/tyler/Documents/doom-ios-2026"   # wherever the tree used to live
grep -rlF -- "$old_path" App/build
```

Any hit means the tree was moved and the cache is poisoned.

**No `| head`,** for two separate reasons this repo has already paid for.
`head` masks `grep`'s exit status, and a masked query status is how a check
fails open (`docs/learnings/masked-exit-status-fails-open.md` — four times
now). And under `pipefail`, `head` closing the pipe kills `grep` with SIGPIPE
so it exits 141 *on a match*, inverting the check
(`docs/learnings/pipefail-with-early-exit-consumer.md`). That second one is
**size-dependent — it only bites above ~64K of output**
(`docs/learnings/pipefail-turns-an-early-quit-into-a-failure.md`), which is
exactly what makes it dangerous here: a one-file test case exits 0 and looks
fine, while a real poisoned `App/build` matches hundreds of files, crosses the
buffer, and reports healthy. Measured 2026-09-16: the `| head` form returned 0
against a single planted match, so testing it small proves nothing.

`-F` because a path is a fixed string, and `--` because it starts with `/`.

More generally, before blaming a diff for `Unable to find module dependency`,
scan the build log for `located outside of the allowed root paths` — the error
alone has several causes, but that warning settles it.

Related: `docs/learnings/cli-builds-race-xcodes-previews.md` gives CLI builds
their own `-derivedDataPath` for a different reason (Xcode previews racing the
shared cache). Neither protects against a moved checkout — the stale cache is
inside the repo either way.
