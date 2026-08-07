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
