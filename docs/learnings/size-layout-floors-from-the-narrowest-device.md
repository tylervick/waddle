# A layout floor sized from the reference device fits nothing, and a bare fit is not a fit

Two consecutive attempts at the shelf's above-the-fold problem (#184 → PR #177's
regression, then #204 → PR #203) both missed, and they missed the same two ways.
Anything that budgets space against a viewport is liable to repeat it.

## The floor has to come from the narrowest device the target admits

`Theme.gridMinimumTileWidth` was 200 pt. The reasoning that produced it was
about the *reference* device — the iPhone 17 Pro `ui-tests.yml` runs on — and
200 pt looks generous there. It is not: 200 pt fits **one** column on every
single iPhone the deployment target admits, the 440 pt iPhone 17 Pro Max
included, because two 200 pt columns plus a 16 pt gap need 416 pt of content
width and the widest phone offers 408.

One column makes the first tile row 3:4 of the *entire* content width — 544 pt
on that widest phone — which is most of a viewport on its own. Everything
downstream (the welcome card's budget, `minimumGridPeek`, the hero cap) was then
tuned to survive a row that should never have been that tall.

**Enumerate the widths; do not reason from the device in front of you.** The
runtime is authoritative and takes one command:

```bash
xcrun simctl list runtimes -j    # -> supportedDeviceTypes for the iOS 26 runtime
/usr/libexec/PlistBuddy -c 'Print :mainScreenWidth' \
  "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone 13 mini.simdevicetype/Contents/Resources/profile.plist"
```

Two surprises came out of doing that, and both change the answer:

- The narrowest supported iPhone is **360 pt** — the iPhone 12 mini and 13
  mini, which the iOS 26 runtime still lists. It is *not* the 375 pt iPhone SE,
  which is the device most people name when asked for the small one.
- Issue #204's own measurement table is mislabelled: it reads "iPhone 17 Pro
  (440 × 956 pt)". The 17 Pro is 402 × 874; 440 × 956 is the 17 Pro **Max**. The
  table pairs one device's width with the other's height, which is how a −30 pt
  slack was computed for a combination no user has. `SIMULATOR_DEVICE` in
  `ci.yml` and `ui-tests.yml` is `iPhone 17 Pro`, so the row that actually flakes
  in CI is the 402 pt one.

`ShelfHeroLayoutTests.SupportedDevice.allPhones` now carries every distinct
width with its provenance, and the column-count assertions run over all of them
rather than over a chosen one.

## Do not land the decision on the boundary, in either place

Two columns at 360 pt need a floor of at most `(360 − 32 − 16) / 2 = 156` pt.
156 is therefore the *obvious* answer and the wrong one: at exactly 156 the
adaptive fit evaluates to precisely 2.0 columns, and any disagreement between
our arithmetic and SwiftUI's — or a point of unexpected safe-area inset — tips
it back to one. The floor is 150, inside a usable window of roughly 126–156.

The same mistake in the other dimension is what made PR #203 flaky rather than
fixed. Its budget accepted a hero zone when the first tile row ended *exactly*
on the fold, which on the CI device left about 16 pt of slack — inside
`welcomeCardHeight`'s own modelling error, since that height is summed from
`UIFont` line heights while SwiftUI lays out the real card. Two attempts of one
`ui-tests.yml` run on one commit (`32282595546`, `9584cf29`) disagreed with each
other: one tap landed, the next did not.

`ShelfHeroLayout.minimumFoldClearance` is that margin, named and pinned at
44 pt — spec §5's minimum tap target, which is also comfortably more than the
largest single thing the card's estimate can miss (one unmodelled
`.subheadline` line plus the button style's padding).

**A budget satisfied by `>= 0` is not a budget.** If a fit is computed from
measured text metrics, the requirement needs a margin wider than the
measurement's own error, or "it fits" means "it fits about half the time".

## Prove the test discriminates, because these tests pass at HEAD by default

A column-count or margin test written against current behaviour passes whether
or not the behaviour is right. Both were checked by reverting the constant and
watching them fail: floor back to 200 → nine tests red; clearance to 0 →
`testAZoneThatOnlyJustFitsIsRejected` red. Restore, green.

One of those first drafts asserted on the exact boundary
(`budget == card + clearance`) and failed: a tile row is 261.33 pt at the
reference width, which no binary float holds exactly. Sit a point either side of
a boundary rather than on it — in the tests as much as in the constants.

Related: [hero-zone-must-leave-a-tappable-tile-row.md](hero-zone-must-leave-a-tappable-tile-row.md),
which is the first half of this story, and
[ui-tests-are-red-at-head.md](ui-tests-are-red-at-head.md) — `WaddleUITests`
runs on no pull request, so `gh workflow run ui-tests.yml --ref <branch>` is the
only pre-merge signal for changes like this.
