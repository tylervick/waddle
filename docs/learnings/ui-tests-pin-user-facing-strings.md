# A copy change breaks the UI test that pins the old literal — days later, under someone else's name

`ShipUITests.testAboutScreenShowsLicensesAndBuild` finds the About screen's
license row by its full visible label:

```swift
let gplRow = app.descendants(matching: .any)["Waddle & Woof! — GPL-2.0"]
```

Commit `35a4561` (2026-08-17) relicensed the app to GPL-3.0 — required by the
Apache-2.0 SONiVOX EAS dependency — and renamed that row to
`Waddle & Woof! — GPL-3.0`. Nothing in that commit touched a test, nothing
failed at merge time (the UI suite runs nightly, not per PR), and the row the
test looks for simply stopped existing. Every full `ui-tests.yml` run since
went red with "GPL-2.0 license row never appeared".

**Why the misattribution, twice.** The failure surfaced days after its cause,
bundled with an unrelated `EngineSmokeTests` red, so the natural read was "the
UI suite is red because of the layout work" — and #184's five-merge window
analysis never contained the relicense at all. A later bisect from CI history
then blamed the diagnostics PR #206, because the last green run (on the #205
branch, 2026-08-19) sat between them. That green run was a *filtered* dispatch:
it executed **zero** `ShipUITests` cases. A run can only clear the suites it
actually ran — `grep -c 'Test Case.*ShipUITests'` on the run log is the
ten-second check that would have caught it.

**The two rules this buys.**

- Changing user-facing copy? Grep `App/UITests/` for the old literal in the
  same change. UI tests here deliberately find elements by visible label when
  no identifier exists, so copy is load-bearing test surface.
- Bisecting from CI history? Before trusting any green run as a bound, confirm
  it executed the suite that is now failing. A filtered or partial run is not
  evidence.

**Provenance:** found 2026-08-21 while untangling the standing UI-tests red;
the fix PR corrects the literal and cites this file.
