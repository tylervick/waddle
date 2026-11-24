# A failed count assertion followed by an index crashes the whole test runner

XCTest's `continueAfterFailure` is `true` by default, so a failed `XCTAssert`
records the failure and lets the test keep running. In
`TouchMenuTests.testTapsOpenMenusAndPromptsNeedTheButtons` an
`XCTAssertGreaterThanOrEqual(targets.count, 5, …)` was followed by
`targets[targets.count - 1]`. In UI Tests run 45321359124 (`main`, 9e812b7,
2026-11-24) the menu did not open, `targets` was empty, and the next line
stopped `WaddleUITests-Runner` with
`Swift/ContiguousArrayBuffer.swift:695: Fatal error: Index out of range`.
xcodebuild then printed "Restarting after unexpected exit, crash, or test
timeout" and relaunched the runner. One assertion failure had become a crashed
runner: the failure's own message is all that survives of the test, its
teardown blocks never run, and the log reads like a second, unrelated crash.

**Get the value through a throwing check before indexing it**, so a short list
ends the test where it fails:

```swift
let targets = try XCTUnwrap(list.count >= 5 ? list : nil, "wanted 5, got \(list.count)")
```

`TouchMenuTests.mainMenuTargets` is that check for the main menu's item
centres; `openSaveList` in the same file already returned nil instead of
indexing. `try XCTSkip…` is not a substitute: it reports a failure as a skip.

This is not an executable check: telling a guarded index from an unguarded
one needs data flow, and a grep over `App/UITests` would flag every index.
