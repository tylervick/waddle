# `--no-renames` puts paths in the diff that do not exist at HEAD

`git diff --name-only` has rename detection on by default and prints only a
rename's destination path. `Scripts/check-red-green.sh` must not use that
default: its revert would delete the new name, never restore the old one, and
score a pure `git mv` as `proved` off a tree that never existed. So it passes
`--no-renames`, and the rename arrives as a delete plus an add.

That fix is correct and must stay. Its second-order consequence is the trap:
**every changed-file list now contains departure paths that do not exist at
HEAD**, and they are indistinguishable from plain deletions — deliberately so,
since telling them apart is exactly the rename heuristic that was just turned
off. Any per-path rule over that list inherits the ambiguity.

The rule that broke was "a changed script with no `Scripts/test-<name>.sh` is
unproven, so contribute `no-test`". Applied to a departure path it demands a
suite for code the change removed: unsatisfiable, so the `no-test` is not a
cautious reading of thin evidence, it is a verdict with no evidence at all. And
it is wrong in the expensive direction — `no-test` outranks `proved` in the
worst-of, so renaming a script and its suite together, an ordinary refactor,
masked the real proof the moved suite had earned.

## The rule

Only a path that **still exists at HEAD** can be unproven; there has to be
something at HEAD for a test to be about. A path absent from HEAD contributes
neither a suite nor a `no-test`. The boundaries are narrow on purpose: a suite
matching a departed name that *does* still exist at HEAD is real evidence about
the deletion and is still run, and the arriving half of a rename is an ordinary
source file that still owes a suite by name.

## Where else to look

Anywhere a changed-file list is treated as "things that exist now" — a coverage
demand, a lint-the-changed-files step, a "does each source have an owner"
check. The tell is a rule that asks something *of* a path rather than *about*
the diff. This one is executable rather than restated: `Scripts/test-check-red-green.sh`
cases 29–32 pin the rename, the boundary, the plain-deletion arm, and the
domain-level `no-test` that is deliberately left alone. Case 29 is the one that
discriminates — it reads `no-test` against the old rule and `proved` against
this one.
