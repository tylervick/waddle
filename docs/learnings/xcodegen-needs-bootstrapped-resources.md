# XcodeGen refuses to generate before the resources are fetched

`mise run generate` in a fresh worktree fails like this:

```
2 Spec validations errors:
	- Target "WADdle" has a missing source directory ".../App/Resources/GameData"
	- Target "WADdle" has a missing source directory ".../App/Resources/woof.pk3"
```

It reads like a bad `App/project.yml`, and it is not. Both paths are build
*outputs* and both are ignored — `App/Resources/woof.pk3` by `.gitignore`,
`App/Resources/GameData` by `.git/info/exclude`, which worktrees share with the
primary checkout. A fresh clone or worktree therefore has neither, and XcodeGen
validates its source list before it writes anything, so the failure lands on
`generate` rather than on the build step that actually needs the files.

`Scripts/build-engine.sh` stages `woof.pk3`; `Scripts/fetch-freedoom.sh`
downloads `GameData/`. `mise run bootstrap` runs both (plus `generate`), and is
the documented path — the trap is only that `generate` alone looks like it
should work, since `WADdle.xcodeproj` is itself gitignored and regenerating it
is otherwise a fast, self-contained step.

When `Vendor/` is already populated (an Orca per-run worktree inherits it), the
engine does not need rebuilding and copying the two resource paths across from
the primary checkout is enough:

```bash
cp -R /path/to/primary/App/Resources/GameData App/Resources/GameData
cp /path/to/primary/App/Resources/woof.pk3 App/Resources/woof.pk3
```

Both are ignored, so this leaves the worktree clean — check with
`git check-ignore -v App/Resources/GameData App/Resources/woof.pk3` before
trusting that, rather than after `git status` has already surprised you.

Related: [worktree-setup-traps.md](worktree-setup-traps.md) covers the other two
worktree traps (the `Vendor` symlink and the stale CMakeCache).
