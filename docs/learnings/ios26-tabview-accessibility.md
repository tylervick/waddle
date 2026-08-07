# iOS 26 TabView tab-bar buttons ignore accessibility identifiers

Setting `.accessibilityIdentifier` on a `TabView` tab never reaches the rendered
tab-bar button, so UI tests cannot address tabs the usual way.

**What to do instead:**

- Switch tabs by label: `app.tabBars.buttons["Play"]`, `app.tabBars.buttons["Library"]`.
- Assert the resulting pane by identifier: `app.otherElements["playTab"]`,
  `app.otherElements["libraryTab"]`.
- The add-PWAD menu is `app.buttons["addPWADMenu"].tap()` followed by
  `addPWADButton-<display>`.

**Provenance:** Plan 2 Task 8, recorded as the explicit UI-test contract for
Task 9.
