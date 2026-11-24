# A list row that is a Button stays tappable in Edit mode, and its label swallows "Remove"

**Symptom.** A UI test put Sources (#502) into Edit mode and tapped the first
button whose label began "Delete" or "Remove". The sheet closed, the shelf
said "2 already in library", and the next step failed: the tap had landed on
the row, and the row's action downloaded the real Freedoom release over the
network, from a UI test that was meant to fetch nothing.

**Cause, two parts, measured on the iOS 27.0 simulator.**

- In a SwiftUI `List` whose row is a `Button`, Edit mode does not disable the
  button. A tap anywhere on the row but the delete control still runs its
  action.
- In Edit mode the row button's accessibility label becomes
  `"Remove, <row label>"`, and the delete control itself is not a button: it
  is an **image** labelled `remove` (identifier `minus.circle.fill`), with the
  row button's frame covering it. So a query for buttons labelled "Remove…"
  finds the row, and `app.buttons` never finds the control. After a tap on the
  image, the confirming control is a button labelled `Delete`.

**Fix.** Hold `EditMode` in the view (`.environment(\.editMode, $editMode)`)
and disable a row whose tap does something while `editMode.isEditing`
(`SourcesSheet`). In a test, tap `app.images["remove"].firstMatch`, then
`app.buttons["Delete"]` (`PlayTabTests.testSourcesOffersFreedomAndRestoresItAfterDelete`).
Edit's delete is taps only, so it also works where a swipe does not (an open
iPhone Duo, see `iphone-duo-simulator-traps.md`).
