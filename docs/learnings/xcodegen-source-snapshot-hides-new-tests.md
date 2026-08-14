# A new test file does not fail — it silently does not exist

`App/project.yml` points targets at directories (`sources: [Tests]`, `- path:
Sources`). XcodeGen resolves those into an **explicit file list** at
`xcodegen generate` time and writes it into `App/WADdle.xcodeproj`. The
directory is not consulted again at build time.

So a source file added after the last generate is not "missing" in any way
the build can report. It is simply not a member of the target:

```
$ # write App/Tests/TouchOverlayLayoutTests.swift, then:
$ xcodebuild ... -only-testing:WADdleTests test
     Executed 193 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

193 was the count *before* the new file. The suite is green, the new tests
did not run, and nothing on screen says so. Run `mise run generate` and the
same command reports 221.

This is the same failure shape as
[`exit-status-conflates-failed-with-never-ran.md`](exit-status-conflates-failed-with-never-ran.md):
a green result that means "never ran", read as "passed".

## Why it bites hardest during TDD

The red step is the whole point — you write a test and watch it fail to
prove it can catch the bug. If the file was never compiled in, the red step
reports **green** instead. Reading that as "huh, it passes already" and
deleting the test is the natural next move, and it throws away a correct
test to satisfy a build artifact.

## What to do

Run `mise run generate` after adding **any** file under `App/Sources` or
`App/Tests`, before the first test run — not just after editing
`project.yml`. If a brand-new test passes on its very first run, do not
reach for an explanation about the code: check the executed-test count
first.

The generate is cheap and idempotent, so there is no reason to try to
remember whether this particular change needs it.

## Related

`App/project.yml` already documents a *narrower* case of this around
`Generated/BuildInfo.generated.swift` — a gitignored file that does not
exist at generate time gets no Compile Sources slot at all, which is why it
has an explicit `optional: true` entry instead of relying on the directory
scan. That comment explains the fix for one known file; this note is about
every file you add by hand.
