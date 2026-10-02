# The layout suites' chrome was assumed, and went stale when the bar changed

`ShelfHeroLayoutTests`, `AccessibilityTextSizeLayoutTests` and
`PlayableDetailLayoutTests` model the viewport as the screen's point height
less "the chrome above and below the scroll view". Until 2026-10-02 that
chrome was reasoned, not measured: ~96 pt for a large-title navigation bar,
34 for the home indicator, 44 + 21 in landscape, with a comment calling the
large-title figure "the taller reading — an inline bar is nearer 44".

Two things moved underneath that. The shelf's bar became inline when the
wordmark replaced the title (PR #305), and on the iOS 27 runtime the inline
bar is *taller* than the large one had been budgeted, not shorter. Read off
the live scroll view with a temporary `onGeometryChange` readout (iPhone 17
Pro, iPad Pro 13-inch, both orientations):

| | top | bottom | sides | fixture had |
|---|---|---|---|---|
| iPhone 17 Pro portrait | 116 | 34 | 0 | 96 + 34 |
| iPhone 17 Pro landscape | 78 | 20 | 62 | 44 + 21, sides 59 |
| iPad Pro 13 portrait | 86 | 25 | 0 | 96 + 20 |
| iPad Pro 13 landscape | 86 | 25 | 0 | 96 + 20 |

Every phone fold budget was 20 pt optimistic in portrait and 33 pt in
landscape (plus 6 pt of width); the pad fixtures were already the harder
reading. Correcting the numbers turned four assertions red, all real: the
stacked landscape-phone hero sat on its 96 pt floor at the default text size,
the first tile row peeked under a tap target at accessibility sizes, and the
compact welcome card cleared the fold by 40.6 pt. The fix was a product one
(the compact-height arrangement, design-system spec §9), not a fixture one.

**Two things to carry forward.** A fixture that describes chrome is a claim
about a runtime and a bar style, and has to be re-measured when either
changes — the readout is six lines in the view and one UI-test run. And the
"harder reading" comment was the trap: it made the assumption look
conservative, so nobody checked it. State what was measured, where, and when;
let the reader decide whether it is still the harder reading.

**Provenance:** found while reconciling the suites with the viewport
measurement in `geometry-proxy-size-already-excludes-safe-area.md`.
