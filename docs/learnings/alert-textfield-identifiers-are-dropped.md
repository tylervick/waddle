# XCUITest against SwiftUI alerts and dialogs: two quirks, one file

A `TextField` placed inside a SwiftUI `.alert { }` content closure does not
forward its `.accessibilityIdentifier` to the `UIAlertController` UIKit
actually renders. The field is visible, focused, and holds the right value —
`app.textFields["myID"]` still never matches it, which reads exactly like the
alert never appeared unless you check the value/focus state directly. The fix
is to stop addressing the field by identifier and query the alert itself:
`app.alerts["<alert title>"].textFields.firstMatch`. Setting the identifier on
the `TextField` anyway is harmless — it documents intent even though nothing
resolves it — so leave it in place.

The second quirk lives in the same family: a `.confirmationDialog` button
surfaces **twice** in the accessibility hierarchy (the sparse-match dump shows
one `Button` with the target identifier nested directly inside another with
the same identifier and label), so `app.buttons["myAction"].tap()` fails with
"multiple matching elements found" rather than finding a unique element. Query
through `.firstMatch` instead: `app.buttons.matching(identifier: "myAction").firstMatch.tap()`.

**Provenance:** plan 2 Task 5, 2026-09-18.
