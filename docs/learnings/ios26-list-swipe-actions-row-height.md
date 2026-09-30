# iOS 26 List swipe actions change shape with row height

Swipe-action rendering is driven by **row height**, not by any modifier:

- A single-line row gets a full-height red capsule with "🗑 Delete" inside it.
- A taller row — LibraryView's two-line row at roughly 66pt — gets a fixed-size
  red icon button with the "Delete" caption *below and outside* the red.

The second looks like a clipped background but is the system idiom; the Files
app renders identically.

Stripping `.accessibilityElement(children: .combine)`, `.contextMenu`, and
`.deleteDisabled` changes nothing — this was bisected empirically on 2026-07-31.
The only escape hatch is an explicit `.swipeActions` whose button label is
text-only (`Button("Delete", role: .destructive)`), which restores the
full-height capsule even on a tall row; `Label("Delete", systemImage: "trash")`
renders the same as `.onDelete`.

**Decision:** keep the stock look. Do not re-investigate.

**Re-measured 2026-09-30 on iOS 27.0 (issue #244), because the iOS 27 SDK
added `swipeActionsContainer()`, a lever the 2026-07-31 bisect could not have
tried.** It changes nothing here. `FilesScreenTests.testSwipingATallImportedRowRevealsDelete`
swipes the imported SCYTHE row (bundled rows are `deleteDisabled`, so they
have no action to reveal) and attaches a screenshot; the same run with
`.swipeActionsContainer()` behind `if #available(iOS 27.0, *)` on the `List`,
and again on the row, produced images that differ from the stock one only in
the status-bar clock (1884 and 541 pixels of 3.16 million). All three are in
`images/ios27-swipe-tall-row-*.png`: the fixed-size red icon button with the
"Delete" caption below and outside the red, on every variant. So iOS 27
renders the tall-row swipe exactly as iOS 26 did, the modifier does not touch
it at either site, and the decision above stands with that date on it. No
source change was kept.
