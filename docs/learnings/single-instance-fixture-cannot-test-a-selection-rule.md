# A one-instance fixture cannot test a rule that *selects* among instances

`Scripts/whats-to-test.sh` picks the tag that anchors its changelog range. The
rule that matters on the release path is "the newest `build-*` tag **below**
the build being annotated", because `.github/workflows/testflight.yml` pushes
`build-<N>` at HEAD in the step immediately *before* the notes step — so at
that moment the newest tag is the current build, sitting on HEAD, and
`build-N..HEAD` is empty on every single release.

Nine tests covered the assembly, including the changelog text, the preamble
ordering, the bootstrap fallback and a real `git tag` failure. Every one of
them built a fixture with **exactly one** `build-*` tag. With one tag, "newest
tag" and "newest tag below N" name the same commit, so all nine passed under
either rule and the feature shipped unable to produce a changelog at all —
green tests, and with a preamble present, a green *release* with the changelog
silently gone.

**The property under test was a choice, and a choice needs at least two
candidates to be observable.** One element does not exercise "pick the right
one"; it exercises "pick the only one". The same shape hides a wrong `head -1`
versus `tail -1`, a sort direction, a "most recent", a "highest version", a
"first match" — anywhere the code ranks a set and the fixture holds a set of
size one.

## The check

`Scripts/test-whats-to-test.sh` case 20 is the executable form: two tags
(`build-206`, `build-207`) with the higher one at HEAD, attaching build 207,
asserting the notes say "since build **206**" and carry the bullets. It fails
against the pre-fix selection with `error: no changes since build-207`, which
is exactly what the release path produced.

When a test's fixture has one of something the code chooses among, ask what
the assertion would do with two. If the answer is "pass either way", the test
is measuring the plumbing, not the rule.
