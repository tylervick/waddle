# "The sheet never opened" usually means the sheet opened and the row is below the fold

A `XCTAssertTrue(app.buttons["x"].waitForExistence(timeout: 5))` that fails
immediately after tapping something that presents a sheet reads as *the sheet
never presented*. That inference is wrong often enough to be worth distrusting
by default.

SwiftUI's `Form` and `List` are lazy collection views, and `LazyVGrid` is a
lazy grid. None of them instantiate rows below the visible bounds, so those
rows are not merely off-screen — they are **absent from the accessibility
hierarchy**, and every XCUITest query for them fails exactly the way a missing
screen does. The failure is indistinguishable from a presentation that never
happened unless you go and look.

**Look before theorising — the evidence is already in the result bundle.** Run
the test with `-resultBundlePath`, then:

```bash
xcrun xcresulttool export attachments --path out.xcresult --output-path ./attach
# manifest.json maps every attachment to its test; the useful one is named
# "App UI hierarchy for <bundle id>"
```

That file is the full element tree *with frames*, captured at the moment of
failure. It settles the question in one read: if the sheet's own navigation bar
and its first rows are in the tree, the sheet presented and the problem is
geometry. The failure message in the plain xcodebuild log carries a shorter
version of the same evidence — the `from input {( ... )}` list is the elements
that *did* match the query's type, so a `detailPlayButton` sitting in that list
while `detailSchemePicker` is missing already tells you the sheet is up.

**Provenance:** issue #169, 2026-08-16. Both failing tests were reported as
"the detail sheet never presented", with a SwiftUI context-menu dismissal race
as the suspected cause. The hierarchy showed `PlayableDetailView` presented and
correct every time: its header art was drawn at the *tile* aspect ratio (3:4),
which at a sheet's full width came out 481 pt tall, so the Controls picker and
the preset Edit button sat below the fold of a lazy `Form` and were never
built. The fix was a height cap (`PlayableDetailLayout`), not a presentation
fix — and `ShelfHeroLayout` already existed, having been written for the same
defect one screen over, where a `LazyVGrid` hid the whole library behind an
oversized hero.
